#!/usr/bin/env python3
"""TTActualidad V2: consumidor editorial continuo, aislado y sin publicación.

SOLO con --run y bandera local de instalación. Elige desde el Top30 vigente
por puesto 1..30. Cada tendencia se entrega al ciclo ChatGPT existente,
con navegador y chat efímeros, captura y verificación GitHub.
No hace polling de V1 ni publica, nunca reenvía un ID/revisión dudoso.
"""
import argparse
import json
import pathlib
import sys
import time
from datetime import datetime, timezone

import editorial_run_v2 as core
from batch_contract_v2 import verify_persisted
from process_lock_v2 import AlreadyRunning, exclusive_v2_lock
from select_current_top30_v2 import read_history
from auto_editorial_policy_v2 import eligible_plan, enabled_text
from parallel_dispatch_v2 import DisposableWorkerPool
from incident_retry_v2 import MAX_INCIDENT_RETRIES, restart_as_new_revision

ROOT = core.ROOT
LOCK = ROOT / "editorial_batch_v2.lock"
ENABLED = ROOT / "auto-editorial-v2.enabled"
STATUS = ROOT / "daemon-status.json"
SENTINEL = "TT_V2_AUTO_EDITORIAL_ENABLED=YES"
WEB_RETRY_SECONDS = 300


def flag_is_enabled(path=ENABLED):
    try:
        return enabled_text(pathlib.Path(path).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return False


def report(state, **kwargs):
    """Diario operativo LOCAL. Nunca registrar tokens, prompts ni respuestas."""
    event = {"service": "ttactualidad-v2", "at": datetime.now(timezone.utc).isoformat(),
             "state": state, "publication_allowed": False}
    for name in ("trend_id", "revision", "top30_age_minutes", "last_error",
                 "completed", "skipped_local_journals", "active_workers", "workers"):
        if name in kwargs:
            event[name] = kwargs[name]
    core.store(STATUS, event)
    safe = {key: value for key,value in event.items() if key not in ("last_error",)}
    print("TT_V2_AUTO_STATE=" + state, flush=True)
    print("TT_V2_AUTO_STATUS=" + json.dumps(safe, ensure_ascii=False), flush=True)


def check(api, auth, *, directory=core.DIAG_DIR, now=None, active_keys=()):
    queue, _ = core.queue_read(api, auth)
    history = read_history(auth)
    return eligible_plan(queue, history, directory=directory, now=now,
                         active_keys=active_keys)


def retry_web_projection(auth):
    """Retry only the public projection, never the ChatGPT editorial job."""
    try:
        web = core.module("web_top30_v2.py", "ttv2_idle_web_retry")
        web.sync_to_github(auth)
    except Exception as exc:
        print("TT_V2_AUTO_WEB_TOP30_DEFERRED=" + type(exc).__name__, flush=True)
        return False
    print("TT_V2_AUTO_WEB_TOP30_SYNCED=YES", flush=True)
    return True


def settle_failed_job(api, auth, trend_id, revision, *,
                      cleanup_verified, failure_reason):
    """Always close the remote claim after a child finishes or times out.

    A verified-clean child may receive a NEW revision (never reuse its journal).
    Any uncertain Chrome cleanup, missing journal or captured local answer is
    quarantined without another ChatGPT send. CAS fences concurrent RE resets.
    """
    journal = core.DIAG_DIR / ("run-" + trend_id + "-r" + str(revision) + ".json")
    try:
        evidence = json.loads(journal.read_text(encoding="utf-8-sig"))
        if evidence.get("trend_id") != trend_id or evidence.get("revision") != revision:
            evidence = {}
    except (OSError, ValueError, KeyError):
        evidence = {}
    token = evidence.get("lease_token")
    # Record a bounded, actionable category; never copy arbitrary exception
    # strings or transcript content into the public GitHub queue.
    diagnostic = (evidence.get("capture_diagnostic") or {}).get("reason")
    error = str(evidence.get("error") or "").lower()
    if diagnostic in ("chat_target_identity_not_verified",
                      "response_not_stable", "assistant_turn_missing"):
        reason = "capture_" + diagnostic
    elif "403" in error or "rate limit" in error:
        reason = "github_access_or_rate_limit"
    elif "chatgpt no está listo" in error or "chatgpt not ready" in error:
        reason = "chat_not_ready"
    elif "cdp no disponible" in error or "chrome" in error:
        reason = "chrome_or_cdp_failure"
    else:
        reason = failure_reason
    for attempt in range(4):
        queue, sha = core.queue_read(api, auth)
        row = (queue.get("items") or {}).get(trend_id) or {}
        if row.get("revision") != revision:
            return "revision_changed"
        if row.get("status") == "captured_review":
            return "already_captured"
        if row.get("status") != "in_progress":
            return "already_released"
        if token and (row.get("lease") or {}).get("token") != token:
            return "lease_changed"
        row["capture_recovery_reason"] = reason
        can_retry = (cleanup_verified and token
                     and not evidence.get("reply_captured")
                     and (int(row.get("incident_retries", 0)) < MAX_INCIDENT_RETRIES
                          or row.get("manual_retry_requested_at")))
        if can_retry:
            updated = restart_as_new_revision(
                queue, trend_id, chrome_clear=True, recovery_checked=True,
                finished_lease_token=token,
                previous_chat_url=evidence.get("chat_url") or "")
            result = "new_revision"
        else:
            # Even a failed Chrome cleanup must not leave an apparently live
            # 40-minute lease. The quarantine cannot be retried until the
            # separate incident worker proves all owned Chrome is closed.
            row["status"] = "capture_recovery"
            if not cleanup_verified:
                row["capture_recovery_reason"] = "session_cleanup_unverified"
            elif not token:
                row["capture_recovery_reason"] = "session_journal_unverified"
            elif evidence.get("reply_captured"):
                row["capture_recovery_reason"] = "captured_locally_needs_persist"
            else:
                row["capture_recovery_reason"] = "automatic_retry_limit_reached"
            row.pop("lease", None)
            row["updated_at"] = core.utcnow()
            queue["pending_ids"] = [item["trend_id"] for item in sorted(
                queue["items"].values(),
                key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
                if item["status"] in ("pending", "review_pending", "in_progress",
                                      "capture_recovery", "captured_review")]
            queue["pending_count"] = len(queue["pending_ids"])
            updated = queue
            result = "quarantined"
        try:
            core.queue_write(api, auth, sha, updated, "finish V2 editorial attempt " + trend_id)
            return result
        except RuntimeError as exc:
            if "GitHub conflict/changed revision" not in str(exc) or attempt == 3:
                raise
            time.sleep(min(attempt + 1, 3))
    return "settlement_deferred"


def run_forever(poll_seconds=90, max_jobs=0, workers=3):
    if not flag_is_enabled():
        raise RuntimeError("AUTORUN BLOQUEADO: instalar y habilitar primero V2")
    api = core.module("persist_capture_github.py", "ttv2_auto_github")
    auth = api.token()
    completed = 0
    attempts_started = 0
    with exclusive_v2_lock(LOCK):
        # El perfil autenticado solo sirve de semilla: cada chat obtiene una
        # copia propia que se elimina tras cerrar su Chrome, incluso al fallar.
        pool = DisposableWorkerPool(
            core.PROFILE, workers, source_running=core.profile_pids,
            env_key="TT_V2_EDITORIAL_PROFILE",
            logs_dir=ROOT / "editorial-parallel-logs")
        report("STARTED", completed=completed, workers=workers)
        print("TT_V2_AUTO_START=YES", flush=True)
        print("TT_V2_AUTO_PUBLICATION=NO", flush=True)
        last_sync = 0.0
        last_web_sync = time.monotonic()
        unsettled = {}
        try:
            while flag_is_enabled():
                for done in pool.reap():
                    tid, rev = done["trend_id"], done["revision"]
                    if (done.get("timed_out") or done.get("profile_cleanup_error")
                            or done["exit_code"]):
                        unsettled[(tid, rev)] = done
                        report("SESSION_TIMEOUT_8MIN" if done.get("timed_out")
                               else "JOB_NEEDS_REVIEW",
                               trend_id=tid, revision=rev, completed=completed,
                               active_workers=len(pool.active),
                               last_error=done.get("profile_cleanup_error")
                                   or "worker_exit_" + str(done["exit_code"]))
                        continue
                    try:
                        final, _ = core.queue_read(api, auth)
                        journal = core.DIAG_DIR / ("run-" + tid + "-r" + str(rev) + ".json")
                        record = json.loads(journal.read_text(encoding="utf-8-sig"))
                        digest = verify_persisted(final, record)
                        completed += 1
                        print("TT_V2_AUTO_COMPLETED=%s:%s" % (tid, digest), flush=True)
                        report("COMPLETED", trend_id=tid, revision=rev,
                               completed=completed, active_workers=len(pool.active))
                    except Exception as exc:
                        unsettled[(tid, rev)] = done
                        report("JOB_NEEDS_REVIEW", trend_id=tid, revision=rev,
                               completed=completed, active_workers=len(pool.active),
                               last_error=str(exc)[:180])
                        print("TT_V2_AUTO_JOB_NO_RESEND=%s:r%d" % (tid, rev), flush=True)
                # Retain failed settlements in memory while GitHub is down.
                # A transient 403/409 must not permanently strand a lease.
                for key, done in list(unsettled.items()):
                    tid, rev = key
                    try:
                        outcome = settle_failed_job(
                            api, auth, tid, rev,
                            cleanup_verified=done.get("profile_deleted") is True
                                and not done.get("profile_cleanup_error"),
                            failure_reason=("session_8min_timeout" if done.get("timed_out")
                                            else "worker_or_capture_failed"))
                        del unsettled[key]
                        report("JOB_SETTLED", trend_id=tid, revision=rev,
                               active_workers=len(pool.active), last_error=outcome)
                        print("TT_V2_AUTO_SETTLED=%s:r%d:%s" %
                              (tid, rev, outcome), flush=True)
                    except Exception as exc:
                        report("JOB_SETTLEMENT_RETRY", trend_id=tid, revision=rev,
                               active_workers=len(pool.active), last_error=str(exc)[:180])
                # El cron de proyección no necesita Chrome. Si no hay trabajos,
                # reparar el Top30 cada cinco minutos, sin relanzar ningún chat.
                if (not max_jobs and not pool.active and
                        time.monotonic() - last_web_sync >= WEB_RETRY_SECONDS):
                    last_web_sync = time.monotonic()
                    retry_web_projection(auth)
                # A bounded pilot limits launched chats, not only successful
                # completions. An interrupted/failed attempt must not trigger
                # another chat merely because completed stayed at zero.
                if max_jobs and attempts_started >= max_jobs and not pool.active:
                    break
                if not max_jobs and time.monotonic() - last_sync >= poll_seconds:
                    last_sync = time.monotonic()
                    try:
                        re_sync = core.module("sync_private_re_v2.py", "ttv2_direct_re")
                        new_re = re_sync.synchronize_requests(core, api, auth)
                        if new_re:
                            print("TT_V2_AUTO_RE_ENQUEUED=" + str(new_re), flush=True)
                    except Exception as exc:
                        print("TT_V2_AUTO_RE_SYNC_DELAYED=" + type(exc).__name__, flush=True)
                started = 0
                # Simple waves: launch at most N chats, then let all of them
                # finish (or hit their 8-minute watchdog). This guarantees a
                # Chrome-free checkpoint for incident recovery every wave.
                if not pool.active and not max_jobs:
                    try:
                        incident = core.module("incident_worker_v2.py", "ttv2_incident_worker")
                        if incident.process_one(api, auth):
                            print("TT_V2_AUTO_INCIDENT_PROCESSED=YES", flush=True)
                    except Exception as exc:
                        report("INCIDENT_REVIEW", completed=completed,
                               last_error=str(exc)[:180])
                wave_ready = not pool.active
                while wave_ready and pool.available_slot() is not None and (
                    not max_jobs or attempts_started < max_jobs
                ):
                    try:
                        item, age, blocked = check(api, auth, active_keys=pool.busy_keys)
                    except Exception as exc:
                        report("WAIT_SOURCE", completed=completed,
                               active_workers=len(pool.active), last_error=str(exc)[:180])
                        break
                    if item is None:
                        report("WAIT_NO_CURRENT_JOB", completed=completed,
                               active_workers=len(pool.active), top30_age_minutes=age,
                               skipped_local_journals=len(blocked))
                        break
                    tid, rev = item["trend_id"], item["revision"]
                    try:
                        launched = pool.spawn(pathlib.Path(__file__).with_name("editorial_run_v2.py"),
                                              ["--trend-id", tid, "--revision", rev, "--run"],
                                              trend_id=tid, revision=rev)
                    except (OSError, RuntimeError) as exc:
                        report("WORKER_LAUNCH_FAILED", trend_id=tid, revision=rev,
                               active_workers=len(pool.active), last_error=str(exc)[:180])
                        break
                    if launched:
                        started += 1
                        attempts_started += 1
                        report("WORKING", trend_id=tid, revision=rev, completed=completed,
                               active_workers=len(pool.active), workers=workers)
                        print("TT_V2_AUTO_START_JOB=%s:r%d" % (tid, rev), flush=True)
                # A manual pilot with no eligible work should finish instead
                # of keeping a daemon alive indefinitely.
                if max_jobs and not pool.active and not started:
                    report("PILOT_NO_ELIGIBLE", completed=completed)
                    break
                time.sleep(12 if pool.active else poll_seconds)
        finally:
            if pool.active:
                report("DRAINING_ACTIVE_CHATS", completed=completed,
                       active_workers=len(pool.active))
                # The cooperative Windows updater disables the flag while
                # children are running. Do not discard their completion
                # records: they still need a remote settlement on exit.
                for done in pool.wait_for_completion():
                    unsettled[(done["trend_id"], done["revision"])] = done
            for (tid, rev), done in list(unsettled.items()):
                try:
                    outcome = settle_failed_job(
                        api, auth, tid, rev,
                        cleanup_verified=done.get("profile_deleted") is True
                            and not done.get("profile_cleanup_error"),
                        failure_reason="daemon_shutdown_after_child")
                    del unsettled[(tid, rev)]
                    print("TT_V2_AUTO_DRAIN_SETTLED=%s:r%d:%s" %
                          (tid, rev, outcome), flush=True)
                except Exception as exc:
                    report("DRAIN_SETTLEMENT_DEFERRED", trend_id=tid,
                           revision=rev, last_error=str(exc)[:180])
    report("STOPPED", completed=completed)
    print("TT_V2_AUTO_STOPPED=YES", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true",
                        help="Inicio real continuo; requiere bandera local de instalación")
    parser.add_argument("--poll-seconds", type=int, default=90)
    parser.add_argument("--max-jobs", type=int, default=0,
                        help="0 = ilimitado; en pilotos, máximo de chats lanzados")
    parser.add_argument("--workers", type=int, default=3,
                        help="Chats editoriales simultáneos, entre 1 y 6")
    args = parser.parse_args()
    if not 30 <= args.poll_seconds <= 600 or args.max_jobs < 0 or not 1 <= args.workers <= 6:
        parser.error("poll-seconds entre 30 y 600; max-jobs >= 0; workers entre 1 y 6")
    if not args.run:
        api = core.module("persist_capture_github.py", "ttv2_auto_preflight")
        try:
            item, age, blocked = check(api, api.token())
            print("TT_V2_AUTO_MODE=DRY_RUN", flush=True)
            print("TT_V2_AUTO_ENABLED=" + ("YES" if flag_is_enabled() else "NO"), flush=True)
            print("TT_V2_AUTO_TOP30_AGE_MINUTES=" + str(age), flush=True)
            print("TT_V2_AUTO_NEXT=" + (item["trend_id"] if item else "NONE"), flush=True)
            print("TT_V2_AUTO_SKIP_LOCAL_JOURNALS=" + str(len(blocked)), flush=True)
            print("TT_V2_GITHUB_WRITE=NO", flush=True)
            print("TT_V2_MESSAGE_SENT=NO", flush=True)
            print("TT_V2_PUBLISHED=NO", flush=True)
        except Exception as exc:
            print("TT_V2_AUTO_PREFLIGHT_ERROR=" + str(exc), file=sys.stderr, flush=True)
            raise
        return
    print("TT_V2_AUTO_MODE=RUN", flush=True)
    run_forever(args.poll_seconds, args.max_jobs, args.workers)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AlreadyRunning, ValueError) as exc:
        print("TT_V2_AUTO_ERROR=" + str(exc), file=sys.stderr, flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        sys.exit(1)
