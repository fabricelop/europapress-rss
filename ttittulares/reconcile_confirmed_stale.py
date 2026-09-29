#!/usr/bin/env python3
"""Conservative, idempotent cleanup of confirmed stale editorial items.

Dry-run by default. The workflow runs --apply on a fresh main checkout.
Only the three explicitly reviewed 2026-09-29 records may be retired;
never infer duplicates from headline similarity alone.
"""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUEUE = ROOT / "telegram" / "editorial-processing.json"
DECISIONS = ROOT / "ttittulares" / "decisions.json"
PREPARED = ROOT / "ttittulares" / "prepared.json"
OUTBOX = ROOT / "ttittulares" / "editorial-outbox"
# Reviewed in run manual-20260929T190213970Z-chat. Require the original selection
# time and revision so an update or a newly requested rewrite is never suppressed.
LINKS = {
    "e7ae04ea52f6": ("905ccb3cbb37", "PUBLISHED", "SKIPPED_DUPLICATE", "2026-09-29T10:22:59.601383Z"),
    "dba4e8e53c2f": ("5cd174f703c1", "PUBLISHED", "SKIPPED_DUPLICATE", "2026-09-29T14:41:38.983Z"),
    "e24985d2f37b": ("b16da169bfc3", "DISMISSED", "DISMISSED", "2026-09-29T16:04:25.850076Z"),
}

def pending_ids():
    pending = set()
    for path in OUTBOX.glob("*.json"):
        # Be conservative also with malformed pending outboxes.
        pending.add(path.stem.rsplit("-r", 1)[0])
        try:
            pending.add(str(load(path).get("event_id") or ""))
        except (OSError, ValueError, TypeError, AttributeError):
            pass
    return pending

def load(path):
    return json.loads(path.read_text(encoding="utf-8"))

def reconcile(queue, decisions, prepared, pending=None):
    items = queue.get("items", [])
    by_id = {str(x.get("event_id")): x for x in items}
    decision = {str(x.get("event_id")): str(x.get("status", "")).upper()
                for x in decisions.get("items", [])}
    ready = {str(x.get("event_id")) for x in prepared.get("items", [])}
    pending = set(pending or ())
    changes = []
    for event_id, (original, required, target, selected_at) in LINKS.items():
        row, old = by_id.get(event_id), by_id.get(original)
        if not row or row.get("status") != "PROCESSING":
            continue
        if (int(row.get("revision") or 1) != 1 or
                row.get("selected_at") != selected_at or event_id in pending):
            continue
        if not old or (old.get("status") != required and decision.get(original) != required):
            continue
        if event_id in ready:
            continue  # Never hide materialized news.
        # This mapping is explicitly reviewed against the 2026-09-29 run;
        # later substantive updates must be assessed as new revisions.
        row["status"] = target
        row["reconciled_from_event_id"] = original
        row["reconciliation_reason"] = ("already_published_no_material_update"
                                        if required == "PUBLISHED" else "inherited_user_dismissal")
        changes.append((event_id, target, original))
    return changes

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        items = []
        decisions = {"items": []}
        for eid, (original, required, target, stamp) in LINKS.items():
            items.extend(({"event_id": eid, "status": "PROCESSING", "revision": 1, "selected_at": stamp},
                          {"event_id": original, "status": required}))
            decisions["items"].append({"event_id": original, "status": required.lower()})
        items.extend(({"event_id": "41fbb2ed58fc", "status": "PROBLEMATIC"},
                      {"event_id": "new-live", "status": "PROCESSING"}))
        q = {"items": items}
        assert len(reconcile(q, decisions, {"items": []})) == 3
        assert reconcile(q, decisions, {"items": []}) == []
        assert next(x for x in items if x["event_id"] == "new-live")["status"] == "PROCESSING"
        assert next(x for x in items if x["event_id"] == "41fbb2ed58fc")["status"] == "PROBLEMATIC"
        for eid, (original, required, target, stamp) in LINKS.items():
            row = next(x for x in items if x["event_id"] == eid)
            row["status"] = "PROCESSING"
            assert not reconcile(q, decisions, {"items": []}, {eid}) or row["status"] == "PROCESSING"
            row["revision"] = 2
            reconcile(q, decisions, {"items": []})
            assert row["status"] == "PROCESSING"
            row["revision"] = 1
            reconcile(q, decisions, {"items": [{"event_id": eid}]})
            assert row["status"] == "PROCESSING"
            row["status"] = target
        print("RECONCILE_CONFIRMED_STALE_SELFTEST_OK")
        return
    queue, decisions, prepared = load(QUEUE), load(DECISIONS), load(PREPARED)
    changes = reconcile(queue, decisions, prepared, pending_ids())
    print(json.dumps({"mode": "apply" if args.apply else "dry-run", "changes": changes},
                     ensure_ascii=False))
    if not args.apply or not changes:
        return
    stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    queue["updated_at"] = stamp
    QUEUE.write_text(json.dumps(queue, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # Refresh derived counters/compact queue with the existing canonical pipeline.
    # The caller must run apply_editorial_outbox.py and check /api/ttittulares-control.

if __name__ == "__main__":
    main()
