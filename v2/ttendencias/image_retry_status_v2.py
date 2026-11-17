#!/usr/bin/env python3
"""Conservative, read-only image retry status for one editorial revision.

Never infers delivery from a missing URL. Only verified pre-send failures
may be retried without consuming a send attempt.
"""
from datetime import datetime, timezone

MAX_SENDS = 3
MAX_PRE_SEND = 3

def retry_status(records, *, now=None):
    now = now or datetime.now(timezone.utc)
    ordered = sorted(records, key=lambda r: int(r.get("attempt", 0)))
    sends = sum(r.get("status") not in ("pre_send_failed", "starting")
                for r in ordered)
    presends = sum(r.get("status") == "pre_send_failed" for r in ordered)
    if not ordered:
        state = "pending"
    else:
        last = ordered[-1]
        status = last.get("status")
        if status in ("saved", "bound_by_other"):
            state = "saved"
        elif status in ("starting", "send_intent_recorded",
                        "sent_waiting_for_image", "send_unverified"):
            state = "unverified"
        elif status == "pre_send_failed":
            state = "exhausted" if presends >= MAX_PRE_SEND else "retry_pending"
        elif status == "failed":
            obs = last.get("submission_observation") or {}
            if (last.get("error") == "V2_IMAGE_PROMPT_NOT_SUBMITTED"
                and obs.get("composer_inspected") is True
                and obs.get("composer_contains_command") is True
                and obs.get("user_turn_contains_command") is False):
                state = "exhausted" if sends >= MAX_SENDS else "retry_pending"
            else:
                state = "unverified"
        else:
            state = "unverified"
    return {"state": state, "send_attempts": sends,
            "send_limit": MAX_SENDS, "pre_send_failures": presends,
            "pre_send_limit": MAX_PRE_SEND}
