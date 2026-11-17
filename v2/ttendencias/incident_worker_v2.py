#!/usr/bin/env python3
"""Retry one stale incident in a NEW revision and disposable Chrome session.

Called only from the single locked V2 daemon after confirming ChromeProfile
has zero processes. Repo writes require SHA compare-and-swap.
"""
import json
import pathlib
from datetime import datetime, timezone

import editorial_run_v2 as core
from chrome_profile_process_v2 import exact_chrome_profile_pids
from incident_retry_v2 import ranked_incident, restart_as_new_revision


def ensure_no_owned_chrome():
    if core.profile_pids():
        raise RuntimeError("V2_BASE_CHROME_ACTIVE")
    # A detached worker can outlive its Python parent. Never assign a fresh
    # revision or delete its profile while its exact owned Chrome is running.
    for pattern in (core.PROFILE.name + "-Job-*", core.PROFILE.name + "-Parallel-*"):
        for profile in core.PROFILE.parent.glob(pattern):
            if exact_chrome_profile_pids(profile):
                raise RuntimeError("V2_ORPHANED_WORKER_CHROME_ACTIVE")


def process_one(api, auth):
    ensure_no_owned_chrome()
    queue, _ = core.queue_read(api, auth)
    history = core.module("select_current_top30_v2.py", "ttv2_retry_history").read_history(auth)
    incident, age = ranked_incident(queue, history)
    if not incident:
        return False
    trend_id = incident["trend_id"]
    revision = incident["revision"]
    journal_path = core.DIAG_DIR / ("run-" + trend_id + "-r" + str(revision) + ".json")
    journal = None
    if journal_path.exists():
        journal = json.loads(journal_path.read_text(encoding="utf-8-sig"))
        if journal.get("trend_id") != trend_id or journal.get("revision") != revision:
            raise RuntimeError("Diario de incidencia no coincide; detener")
    if journal and journal.get("reply_captured") and journal.get("answer"):
        # Already captured answer might only be missing GitHub commit.
        ensure_no_owned_chrome()
        if journal.get("cleanup_verified") is not True:
            journal["cleanup_verified"] = True
            core.store(journal_path, journal)
        recovery = core.module("recover_existing_chat_v2.py", "ttv2_incident_captured")
        try:
            recovery.recover(trend_id, revision, lock_held=True)
            print("TT_V2_INCIDENT_ORIGINAL_PERSISTED=YES", flush=True)
            return True
        except Exception as exc:
            # Captured text is valuable: do NOT reset this revision to a new
            # message merely because GitHub/Listas were temporarily unavailable.
            print("TT_V2_INCIDENT_CAPTURE_PERSIST_BLOCKED=" + type(exc).__name__, flush=True)
            return False
    # The user explicitly rejected reopening previous ChatGPT conversations.
    # Keep the one-way send evidence, fence the old revision and launch a new
    # chat. A captured answer above is merely persisted, not regenerated.
    if journal and journal.get("message_sent") is True:
        journal["fresh_chat_requested_at"] = datetime.now(timezone.utc).isoformat()
        core.store(journal_path, journal)
    ensure_no_owned_chrome()
    # Revalidate against the latest GitHub revision before transition.
    for attempt in range(4):
        current, sha = core.queue_read(api, auth)
        row = current["items"].get(trend_id) or {}
        if row.get("revision") != revision or row.get("status") != incident["status"]:
            return True  # changed elsewhere, never reset the wrong revision
        refreshed = restart_as_new_revision(
            current, trend_id, chrome_clear=True, recovery_checked=True,
            previous_chat_url=(journal or {}).get("chat_url") or "")
        try:
            core.queue_write(api, auth, sha, refreshed,
                             "retry incident in new revision " + trend_id)
            print("TT_V2_INCIDENT_REQUEUED=" + trend_id + ":r" +
                  str(refreshed["items"][trend_id]["revision"]), flush=True)
            # Projection is best effort; queue is authoritative, next
            # scheduled Top30 sync will retry if this write races with cron.
            try:
                web = core.module("web_top30_v2.py", "ttv2_incident_web")
                web.sync_to_github(auth)
                print("TT_V2_INCIDENT_WEB_SYNC=YES", flush=True)
            except (ValueError, RuntimeError) as exc:
                print("TT_V2_INCIDENT_WEB_SYNC=DEGRADED:" + type(exc).__name__, flush=True)
            return True
        except RuntimeError as exc:
            if "GitHub conflict/changed revision" not in str(exc) or attempt == 3:
                raise
    return False
