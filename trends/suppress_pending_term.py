#!/usr/bin/env python3
"""One-off and repeatable cleanup for the editor's exact suppressed hashtag.

Run inside a checked-out main repository, under the usual Git push lease.
Never delete historical audit; make active requests terminal, remove visible
queue/radar cards and leave every other editorial episode untouched.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

try:
    from suppression import active_request, is_suppressed, purge_pending
    from requests_json import dumps_for_path
except ImportError:
    from trends.suppression import active_request, is_suppressed, purge_pending
    from trends.requests_json import dumps_for_path

ROOT = Path(__file__).resolve().parent


def filter_rows(rows):
    return [r for r in rows if not is_suppressed(r.get("name") if isinstance(r, dict) else r)]


def rewrite_doc(path, doc):
    original = json.loads(path.read_text(encoding="utf-8"))
    if doc == original:
        return False
    path.write_text(dumps_for_path(path, doc), encoding="utf-8")
    return True


def clean_documents(root=ROOT):
    changes = {}
    path = root / "requests.json"
    doc = json.loads(path.read_text(encoding="utf-8"))
    n = purge_pending(doc["requests"])
    if n:
        changes["requests_terminated"] = n
        rewrite_doc(path, doc)

    path = root / "editorial-queue.json"
    doc = json.loads(path.read_text(encoding="utf-8"))
    before = len(doc.get("items", []))
    doc["items"] = [r for r in doc.get("items", []) if not active_request(r)]
    if len(doc["items"]) != before:
        doc["count"] = len(doc["items"])
        rewrite_doc(path, doc)
    changes["queued_removed"] = before - len(doc["items"])

    path = root / "recent.json"
    doc = json.loads(path.read_text(encoding="utf-8"))
    before = len(doc.get("top30") or [])
    for name in ("top10", "top30", "items", "upcoming", "new_entries",
                 "anticipated_entries", "radar_history"):
        value = doc.get(name)
        if isinstance(value, list):
            doc[name] = filter_rows(value)
        elif isinstance(value, dict) and name == "radar_history":
            doc[name] = {k: v for k, v in value.items() if not is_suppressed(
                v.get("name") if isinstance(v, dict) and v.get("name") else k)}
    if isinstance(doc.get("sources"), dict):
        for source in doc["sources"].values():
            if isinstance(source, dict) and isinstance(source.get("trends"), list):
                source["trends"] = filter_rows(source["trends"])
    if isinstance(doc.get("items"), list):
        for rank, row in enumerate(doc["items"], 1):
            row["rank"] = rank
    rewrite_doc(path, doc)
    changes["recent_top30_removed"] = before - len(doc.get("top30") or [])

    path = root / "site-top30-current.json"
    doc = json.loads(path.read_text(encoding="utf-8"))
    before = len(doc.get("items", []))
    doc["items"] = [row for row in doc.get("items", [])
                    if not active_request(row)]
    for rank, row in enumerate(doc["items"], 1):
        row["rank"] = rank
        row["card_id"] = f"rank-{rank}"
    if len(doc["items"]) != before:
        doc["count"] = len(doc["items"])
        rewrite_doc(path, doc)
    changes["site_top30_removed"] = before - len(doc["items"])

    # Assert no suppressed entry survives a user-visible source.
    for name in ("editorial-queue.json", "recent.json", "site-top30-current.json"):
        obj = json.loads((root / name).read_text(encoding="utf-8"))
        for array_name in ("items", "top10", "top30", "upcoming"):
            for row in obj.get(array_name, []):
                if is_suppressed(row.get("name") if isinstance(row, dict) else row):
                    raise AssertionError(f"{name}/{array_name} retains suppressed trend")
    return changes


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if not args.apply:
        parser.error("run --apply only on a verified repository checkout")
    print("TT_TREND_SUPPRESSION_CLEANUP", json.dumps(clean_documents(), sort_keys=True))
