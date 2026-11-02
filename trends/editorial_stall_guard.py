#!/usr/bin/env python3
"""Non-destructive editorial stalled-queue guard for TTendencias.

GitHub's radar only emits a ChatGPT hand-off when an (id, revision) is NEW.
When the receiver misses a hand-off, an existing preparing item can remain
forever even while the Top 30 is refreshing. This guard relaunches the EXISTING
consumer (not a second editorial engine), never edits requests or marks READY.
"""
from __future__ import annotations

import base64
import datetime as dt
import json
import os
import urllib.request

REPO = "fabricelop/europapress-rss"
NOW = dt.timezone.utc
STALE_MINUTES = 30
RUNNING_GRACE_MINUTES = 20
RETRIGGER_COOLDOWN_MINUTES = 20
TRIGGER_REF = "control/ttendencias-run-trigger"


def date(value):
    try:
        d = dt.datetime.fromisoformat(str(value or "").replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=NOW)
    except (ValueError, TypeError, OverflowError):
        return None


def minutes_since(value, now):
    d = date(value)
    return max(0, (now - d).total_seconds() / 60) if d else float("inf")


def active_items(queue):
    return [
        item for item in (queue.get("items") or [])
        if isinstance(item, dict) and item.get("status") in ("preparing", "update")
        and item.get("id")
    ]


def decision(queue, runtime, trigger, now):
    """Return (should_request, reason). Never infer an empty queue from errors."""
    if not isinstance(queue, dict) or not isinstance(queue.get("items"), list):
        return False, "invalid_queue_stop"
    pending = active_items(queue)
    if not pending:
        return False, "no_preparing_or_update"
    overdue = [i for i in pending
               if minutes_since(i.get("requested_at"), now) > STALE_MINUTES]
    if not overdue:
        return False, "pending_below_threshold"
    if not isinstance(runtime, dict) or not isinstance(trigger, dict):
        return False, "remote_state_unavailable"
    runtime_status = str(runtime.get("status") or "").upper()
    if runtime_status in ("RUNNING", "PROCESSING", "IN_PROGRESS") and (
            minutes_since(runtime.get("updated_at"), now) <= RUNNING_GRACE_MINUTES):
        return False, "editorial_run_is_active"
    if minutes_since(trigger.get("requested_at"), now) <= RETRIGGER_COOLDOWN_MINUTES:
        return False, "recent_trigger_already_requested"
    return True, f"stalled_queue_items={len(overdue)} oldest={overdue[0].get('id')}"


def github_file(path, ref):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        raise RuntimeError("No GitHub token; abort without changes")
    url = f"https://api.github.com/repos/{REPO}/contents/{path}?ref={ref}"
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "Cache-Control": "no-store",
        "User-Agent": "ttendencias-editorial-stall-guard",
    })
    with urllib.request.urlopen(req, timeout=20) as response:
        blob = json.load(response)
    return json.loads(base64.b64decode(blob["content"]))


def run():
    # Re-read current main immediately before issuing any control-branch write.
    queue = github_file("trends/editorial-queue.json", "main")
    runtime = github_file("trends/editorial-runtime.json", "main")
    trigger = github_file("trends/run-now-trigger.json", TRIGGER_REF)
    yes, reason = decision(queue, runtime, trigger, dt.datetime.now(NOW))
    print("TTENDENCIAS_EDITORIAL_STALL_GUARD", reason)
    if not yes:
        return False
    # The existing function also deduplicates concurrent updates by SHA and
    # refuses a duplicate fresh request. No queue/status/image modifications.
    from request_pc_editorial import trigger as request_existing_pc_chat
    command_id = request_existing_pc_chat(
        os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
    print("TTENDENCIAS_EDITORIAL_STALL_RECOVERY_REQUESTED", command_id)
    return True


if __name__ == "__main__":
    run()
