#!/usr/bin/env python3
"""Reconstruct proven manual-news ACKs from already-persisted GitHub queues.

No news is created, deleted, published, or re-dispatched. This is an
independent idempotent reconciliation of the existing iPhone receipt ledger.
"""
import json
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ID = re.compile(r"^manual-([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$", re.I)
RECEIPTS = "pilot/ttactualidad-action-receipts.json"
SOURCES = ("telegram/editorial-processing.json", "ttittulares/editorial-queue.json")


def load(path):
    doc = json.loads((ROOT / path).read_text(encoding="utf-8"))
    if not isinstance(doc, dict) or not isinstance(doc.get("items"), list):
        raise ValueError("Invalid authoritative JSON: " + path)
    return doc


def reconcile():
    ledger = load(RECEIPTS)
    receipts = ledger["items"]
    by_request = {str(x.get("request_id") or "").lower(): x for x in receipts}
    candidates = {}
    for path in SOURCES:
        doc = load(path)
        for row in doc["items"]:
            event_id = str(row.get("event_id") or "")
            match = ID.fullmatch(event_id)
            if not match:
                continue
            if row.get("manual_submission") is not True and str(row.get("selection_mode") or "") != "TTACTUALIDAD_MANUAL":
                continue
            if int(row.get("revision") or 0) != 1:
                continue
            request_id = match.group(1).lower()
            # Full processing records are more descriptive, but both sources
            # are authoritative proof that this exact request was persisted.
            candidates.setdefault(request_id, row)

    now = datetime.now(timezone.utc).isoformat()
    changed = 0
    for request_id, row in candidates.items():
        old = by_request.get(request_id)
        if old and str(old.get("status") or "") in {"applied", "already_applied"}:
            continue
        receipt = {
            "request_id": request_id,
            "project": "ttittulares",
            "event_id": "manual-" + request_id,
            "revision": 1, "decision": "manual_news",
            "status": "applied",
            "at": row.get("requested_at") or row.get("selected_at") or now,
            "recovered_from": "persisted_manual_queue",
        }
        # Persisted queue is stronger proof than an obsolete negative receipt,
        # but never turn a mere POST/dispatch into a successful ACK.
        receipts = [x for x in receipts if str(x.get("request_id") or "").lower() != request_id]
        receipts.append(receipt)
        changed += 1
    if changed:
        ledger["items"] = receipts[-2500:]
        (ROOT / RECEIPTS).write_text(
            json.dumps(ledger, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return changed


if __name__ == "__main__":
    print("TT_ACTUALIDAD_MANUAL_ACK_RECONCILED", reconcile())
