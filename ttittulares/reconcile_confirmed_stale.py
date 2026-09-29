#!/usr/bin/env python3
"""Conservative, idempotent cleanup of confirmed stale editorial items.

Dry-run by default. Run --apply only against a fresh checkout, with no active
editorial run, after checking the current app view. Never infer duplicates from
headline similarity alone.
"""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUEUE = ROOT / "telegram" / "editorial-processing.json"
DECISIONS = ROOT / "ttittulares" / "decisions.json"
STATUS = ROOT / "ttittulares" / "status.json"
PREPARED = ROOT / "ttittulares" / "prepared.json"
LINKS = {
    "e7ae04ea52f6": ("905ccb3cbb37", "PUBLISHED", "SKIPPED_DUPLICATE"),
    "dba4e8e53c2f": ("5cd174f703c1", "PUBLISHED", "SKIPPED_DUPLICATE"),
    "e24985d2f37b": ("b16da169bfc3", "DISMISSED", "DISMISSED"),
}

def load(path):
    return json.loads(path.read_text(encoding="utf-8"))

def reconcile(queue, decisions, prepared):
    items = queue.get("items", [])
    by_id = {str(x.get("event_id")): x for x in items}
    decision = {str(x.get("event_id")): str(x.get("status", "")).upper()
                for x in decisions.get("items", [])}
    ready = {str(x.get("event_id")) for x in prepared.get("items", [])}
    changes = []
    for event_id, (original, required, target) in LINKS.items():
        row, old = by_id.get(event_id), by_id.get(original)
        if not row or row.get("status") != "PROCESSING":
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
    args = parser.parse_args()
    queue, decisions, prepared = load(QUEUE), load(DECISIONS), load(PREPARED)
    changes = reconcile(queue, decisions, prepared)
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
