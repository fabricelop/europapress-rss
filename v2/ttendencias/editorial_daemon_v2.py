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

ROOT = core.ROOT
LOCK = ROOT / "editorial_batch_v2.lock"
ENABLED = ROOT / "auto-editorial-v2.enabled"
STATUS = ROOT / "daemon-status.json"
SENTINEL = "TT_V2_AUTO_EDITORIAL_ENABLED=YES"


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


def release_timed_out_job(api, auth, trend_id, revision, *, cleanup_verified):
    """Fence an interrupted attempt by its exact local lease, never resend it.

    If a send was attempted, the interrupted chat moves to capture recovery;
    only a proved pre-send failure can return to Pending.
    """
    if not cleanup_verified:
        return False
    journal = core.DIAG_DIR / ("run-" + trend_id + "-r" + str(revision) + ".json")
    try:
        evidence = json.loads(journal.read_text(encoding="utf-8-sig"))
        token = evidence["lease_token"]
    except (OSError, ValueError, KeyError):
        return False
    for attempt in range(4):
        queue, sha = core.queue_read(api, auth)
        row = (queue.get("items") or {}).get(trend_id) or {}
        if (row.get("status") != "in_progress" or row.get("revision") != revision
                or (row.get("lease") or {}).get("token") != token):
            return False
        sent = bool(row.get("send_intent") or evidence.get("message_sent")
                    or evidence.get("status") == "send_intent_recorded")
        row["status"] = "capture_recovery" if sent else "pending"
        if sent:
            row["capture_recovery_reason"] = "session_8min_timeout_no_resend"
        row.pop("lease", None)
        row["updated_at"] = core.utcnow()
        queue["pending_ids"] = [item["trend_id"] for item in sorted(
            queue["items"].values(), key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
            if item["status"] in ("pending", "review_pending", "in_progress",
                                  "capture_recovery", "captured_review")]
        queue["pending_count"] = len(queue["pending_ids"])
        try:
            core.queue_write(api, auth, sha, queue, "bound V2 chat timeout " + trend_id)
            return True
        except RuntimeError as exc:
            if "GitHub conflict/changed revision" not in str(exc) or attempt == 3:
                raise
            time.sleep(min(attempt + 1, 3))
    return False


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
        try:
            while flag_is_enabled():
                for done in pool.reap():
                    tid, rev = done["trend_id"], done["revision"]
                    try:
                        if done.get("timed_out"):
                            staged = release_timed_out_job(api, auth, tid, rev,
                                cleanup_verified=done.get("profile_deleted") is True
                                and not done.get("profile_cleanup_error"))
                            report("SESSION_TIMEOUT_8MIN", trend_id=tid, revision=rev,
                                   completed=completed, active_workers=len(pool.active),
                                   last_error="recovery_staged" if staged else "recovery_pending")
                            continue
                        if done.get("profile_cleanup_error"):
                            raise RuntimeError("profile_cleanup=" + done["profile_cleanup_error"])
                        if done["exit_code"]:
                            raise RuntimeError("worker_exit_%d log=%s" %
                                               (done["exit_code"], done["log"]))
                        final, _ = core.queue_read(api, auth)
                        journal = core.DIAG_DIR / ("run-" + tid + "-r" + str(rev) + ".json")
                        record = json.loads(journal.read_text(encoding="utf-8-sig"))
                        digest = verify_persisted(final, record)
                        completed += 1
                        print("TT_V2_AUTO_COMPLETED=%s:%s" % (tid, digest), flush=True)
                        report("COMPLETED", trend_id=tid, revision=rev,
                               completed=completed, active_workers=len(pool.active))
                    except Exception as exc:
                        report("JOB_NEEDS_REVIEW", trend_id=tid, revision=rev,
                               completed=completed, active_workers=len(pool.active),
                               last_error=str(exc)[:180])
                        print("TT_V2_AUTO_JOB_NO_RESEND=%s:r%d" % (tid, rev), flush=True)
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
                while pool.available_slot() is not None and (
                    not max_jobs or attempts_started < max_jobs
                ):
                    try:
                        item, age, blocked = check(api, auth, active_keys=pool.busy_keys)
                    except Exception as exc:
                        report("WAIT_SOURCE", completed=completed,
                               active_workers=len(pool.active), last_error=str(exc)[:180])
                        break
                    if item is None:
                        if not max_jobs and not pool.active and not started:
                            # La recuperación puede abrir el perfil base: solo
                            # ejecutar cuando ningún chat independiente sigue vivo.
                            try:
                                incident = core.module("incident_worker_v2.py", "ttv2_incident_worker")
                                if incident.process_one(api, auth):
                                    print("TT_V2_AUTO_INCIDENT_PROCESSED=YES", flush=True)
                                    started += 1
                                    continue
                            except Exception as exc:
                                report("INCIDENT_REVIEW", completed=completed,
                                       last_error=str(exc)[:180])
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
                pool.wait_for_completion()
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
