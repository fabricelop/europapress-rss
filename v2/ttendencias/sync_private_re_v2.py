#!/usr/bin/env python3
"""Fast, read-only D1 RE poll -> idempotent authenticated GitHub V2 queue.

The public endpoint exposes only user-authorized RE revision pairs. GitHub is
still the authoritative queue: every pair is validated again before mutation.
This operates independently of V1, the Top30 schedule, and GitHub cron.
"""
import json
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
    if data.get("schema_version") != 1 or not isinstance(data.get("re"), list):
        raise ValueError("V2 RE public response has unexpected schema")
    if len(data["re"]) > 100:
        raise ValueError("V2 RE public response unexpectedly large")
    return data["re"]


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
        if action == "ENQUEUED":
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
