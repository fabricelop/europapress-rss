#!/usr/bin/env python3
"""Fast, read-only D1 RE poll -> idempotent authenticated GitHub V2 queue.

The public endpoint exposes only user-authorized RE revision pairs. GitHub is
still the authoritative queue: every pair is validated again before mutation.
This operates independently of V1, the Top30 schedule, and GitHub cron.
"""
import json
import copy
import urllib.request
from datetime import datetime, timezone

from re_request_v2 import request_reexplanation
from select_current_top30_v2 import read_history


PUBLIC_RE = "https://ttactualidad-v2-private-test.fabricelop.workers.dev/api/public-editorial-overrides"


def fetch_requests(url=PUBLIC_RE):
    request = urllib.request.Request(url, headers={
        "Accept": "application/json", "User-Agent": "TTActualidadV2-RE-Poll"})
    with urllib.request.urlopen(request, timeout=12) as response:
        data = json.load(response)
    if (data.get("schema_version") != 1 or not isinstance(data.get("re"), list)
            or not isinstance(data.get("incident_rex", []), list)
            or not isinstance(data.get("incident_retry", []), list)):
        raise ValueError("V2 RE public response has unexpected schema")
    if any(len(data.get(k, [])) > 200 for k in ("re", "incident_rex", "incident_retry")):
        raise ValueError("V2 RE public response unexpectedly large")
    return data["re"] + [{**row, "purpose": "incident_hints"}
                          for row in data.get("incident_rex", [])] + [
        {**row, "purpose": "incident_manual_retry"} for row in data.get("incident_retry", [])]


def plan_requested_reviews(queue, history, requests, *, now=None):
    """Plan only valid requested revision pairs; never retry an applied pair."""
    if not isinstance(requests, list):
        raise ValueError("RE entries are not a list")
    timestamp = (now or datetime.now(timezone.utc)).isoformat()
    updated, applied, ignored = queue, [], 0
    for req in requests:
        if not isinstance(req, dict):
            ignored += 1
            continue
        trend_id, base = req.get("trend_id"), req.get("base_revision")
        if not isinstance(trend_id, str) or not trend_id.startswith("trv2-") or not isinstance(base, int) or isinstance(base, bool) or base < 1:
            ignored += 1
            continue
        existing = (updated.get("items") or {}).get(trend_id)
        if not existing or existing.get("revision", 0) > base:
            continue
        if req.get("purpose") == "incident_manual_retry":
            instructions = req.get("instructions", "")
            if (not isinstance(instructions, str) or len(instructions) > 1200 or
                    (instructions and len(instructions.strip()) < 10) or
                    existing.get("revision") != base):
                ignored += 1
                continue
            if existing.get("status") in ("in_progress", "capture_recovery"):
                # D1 cannot authorize an in-flight resend. Stage only a
                # one-shot user request; the incident worker fences the old
                # lease and checks exact Chrome/journal state before resetting.
                if not existing.get("manual_retry_requested_at"):
                    if updated is queue:
                        updated = copy.deepcopy(queue)
                    row = updated["items"][trend_id]
                    row["manual_retry_requested_at"] = timestamp
                    if instructions:
                        row["manual_retry_instructions_pending"] = instructions.strip()
                    applied.append(trend_id)
                continue
            if existing.get("status") not in ("cancelled", "captured_review", "ready", "published"):
                ignored += 1
                continue
            try:
                result, action = request_reexplanation(updated, history,
                    trend_id=trend_id, base_revision=base,
                    entered_top30_at=history.get("observed_at"),
                    requested_at=timestamp, mode="standard",
                    allow_cancelled_incident=True)
            except ValueError:
                ignored += 1
                continue
            if action == "ENQUEUED":
                updated = result
                if instructions:
                    updated["items"][trend_id]["manual_retry_instructions"] = instructions.strip()
                applied.append(trend_id)
            continue
        if req.get("purpose") == "incident_hints":
            hints = req.get("hints")
            if not isinstance(hints, str) or not 10 <= len(hints.strip()) <= 1200:
                ignored += 1
                continue
            if existing.get("revision") != base:
                ignored += 1
                continue
            if existing.get("status") in ("in_progress", "capture_recovery"):
                # No reset, no lease change, no duplicate prompt. The existing
                # run may still finish and must remain recoverable.
                if existing.get("incident_review_hints_pending") != hints.strip():
                    if updated is queue:
                        updated = copy.deepcopy(queue)
                    updated["items"][trend_id]["incident_review_hints_pending"] = hints.strip()
                    applied.append(trend_id)
                continue
            if existing.get("status") not in ("cancelled", "captured_review", "ready", "published"):
                ignored += 1
                continue
            # A finished/terminal incident has no running lease to interrupt.
            # A cancelled attempt is reset only by an explicit RE-X request.
            incident = existing.get("status") == "cancelled"
            try:
                result, action = request_reexplanation(updated, history,
                    trend_id=trend_id, base_revision=base,
                    entered_top30_at=history.get("observed_at"),
                    requested_at=timestamp, mode="x", hints=hints,
                    allow_cancelled_incident=incident)
            except ValueError:
                ignored += 1
                continue
            if action == "ENQUEUED":
                updated = result
                applied.append(trend_id)
            continue
        if req.get("purpose") is not None:
            ignored += 1
            continue
        try:
            result, action = request_reexplanation(updated, history,
                trend_id=trend_id, base_revision=base,
                # The user's D1 entry clock need not equal GitHub's; an
                # informative nonempty timestamp is sufficient for validation.
                entered_top30_at=history.get("observed_at"),
                requested_at=timestamp,
                mode=req.get("mode", "standard"),
                hints=req.get("hints", ""))
        except ValueError:
            ignored += 1
            continue
        if action in ("ENQUEUED", "STAGED"):
            updated = result
            applied.append(trend_id)
    return updated, applied, ignored


def synchronize_requests(core, api, auth):
    """Commit all new RE items in one CAS write (one polling call per cycle)."""
    requests = fetch_requests()
    if not requests:
        return 0
    queue, sha = core.queue_read(api, auth)
    history = read_history(auth)
    planned, applied, ignored = plan_requested_reviews(queue, history, requests)
    if ignored:
        print("TT_V2_RE_POLL_IGNORED=" + str(ignored), flush=True)
    if not applied:
        return 0
    core.queue_write(api, auth, sha, planned,
        "RE explícitos: incorporar " + str(len(applied)) + " revisiones")
    # A successful commit is durable even if the optional Top30 projection
    # fails; the next worker cycle sees the updated revision, never resends.
    try:
        web = core.module("web_top30_v2.py", "ttv2_re_web")
        web.sync_to_github(auth)
    except Exception as error:
        print("TT_V2_RE_POLL_PROJECTION_DELAY=" + type(error).__name__, flush=True)
    return len(applied)
