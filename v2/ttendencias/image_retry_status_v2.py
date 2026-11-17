#!/usr/bin/env python3
"""Bounded image retries in fresh chats; latest successful raster replaces prior."""
from datetime import datetime, timezone

MAX_SENDS = 3
MAX_PRE_SEND = 3
KNOWN = {"starting", "pre_send_failed", "send_intent_recorded",
         "sent_waiting_for_image", "send_unverified", "failed"}


def retry_status(records, *, now=None):
    now = now or datetime.now(timezone.utc)
    ordered = sorted(records, key=lambda r: int(r.get("attempt", 0)))
    sends = sum(r.get("status") != "pre_send_failed" for r in ordered)
    presends = sum(r.get("status") == "pre_send_failed" for r in ordered)
    if not ordered:
        state = "pending"
    else:
        statuses = [r.get("status") for r in ordered]
        last = statuses[-1]
        if last in ("saved", "bound_by_other") or "saved" in statuses or "bound_by_other" in statuses:
            state = "saved"
        elif any(status not in KNOWN for status in statuses):
            state = "blocked"
        elif sends >= MAX_SENDS or (last == "pre_send_failed" and presends >= MAX_PRE_SEND):
            state = "exhausted"
        else:
            # A possibly-sent attempt may be retried only as a NEW chat with a
            # new command ID. The most recent successful raster replaces the old.
            state = "retry_pending"
    return {"state": state, "send_attempts": sends,
            "send_limit": MAX_SENDS, "pre_send_failures": presends,
            "pre_send_limit": MAX_PRE_SEND}


if __name__ == "__main__":
    import json
    print(json.dumps(retry_status([]), ensure_ascii=False))
