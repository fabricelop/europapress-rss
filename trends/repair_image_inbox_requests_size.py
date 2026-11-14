#!/usr/bin/env python3
"""One-time lossless capacity repair for the legacy image-approval Site source.

Historical grouping detail remains intact at immutable Git commit ARCHIVE_COMMIT.
Only two bulky fields from terminal grouping_completed records are omitted
from the current requests.json. All requests, IDs, revisions and states stay.
"""
from __future__ import annotations

import argparse
import json
import subprocess
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "trends" / "requests.json"
ARCHIVE_COMMIT = "9cc6cc13fda474bc4045841690ef103c888a2321"
ARCHIVE_REF = "archive/ttendencias-image-inbox-requests-20261114:trends/requests.json"
SITE_UTF16_LIMIT = 12_000_000
OMITTED = ("grouping_candidates", "published_context")


def load(text: str) -> dict:
    result = json.loads(text)
    if not isinstance(result, dict) or not isinstance(result.get("requests"), list):
        raise ValueError("Expected requests.json with requests list")
    return result


def repair() -> tuple[bytes, dict]:
    current = load(SOURCE.read_text(encoding="utf-8"))
    before = deepcopy(current)
    previous_text = subprocess.check_output(
        ["git", "show", ARCHIVE_COMMIT + ":trends/requests.json"],
        cwd=ROOT,
    ).decode("utf-8")
    archived = load(previous_text)
    old_rows = [x for x in archived["requests"] if x.get("status") == "grouping_completed"]
    old_by_key = {(x.get("id"), int(x.get("revision") or 0)): x for x in old_rows}
    if len(old_rows) != 109 or len(old_by_key) != len(old_rows):
        raise ValueError("Historical archive identity/count changed; no repair")
    live_groups = [x for x in current["requests"] if x.get("status") == "grouping_completed"]
    if len(live_groups) != len(old_rows):
        raise ValueError("New grouping records not in immutable archive; no repair")
    for row in live_groups:
        identity = (row.get("id"), int(row.get("revision") or 0))
        old = old_by_key.get(identity)
        if old is None:
            raise ValueError("Grouping missing in backup: " + str(identity))
        if row.get("grouping_details_archive") not in (None, ARCHIVE_REF):
            raise ValueError("Unexpected archive pointer: " + str(identity))
        for field in OMITTED:
            if field in row and (field not in old or row[field] != old[field]):
                raise ValueError("Grouping detail differs from backup: " + str(identity))
            row.pop(field, None)
        row["grouping_details_archive"] = ARCHIVE_REF

    # Exact reversibility: no non-group item or other grouping field changes.
    restored = deepcopy(current)
    for row in restored["requests"]:
        if row.get("status") == "grouping_completed":
            old = old_by_key[(row.get("id"), int(row.get("revision") or 0))]
            row.pop("grouping_details_archive", None)
            for field in OMITTED:
                if field in old:
                    row[field] = deepcopy(old[field])
    if restored != before:
        # On idempotent re-runs, source already contains archive pointers and
        # omitted details; the reconstruction is intentionally larger.
        original_was_compacted = all(
            x.get("grouping_details_archive") == ARCHIVE_REF
            for x in before["requests"] if x.get("status") == "grouping_completed"
        )
        if not original_was_compacted:
            raise ValueError("Round-trip unexpectedly changed original JSON")

    encoded = (json.dumps(current, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    units = len(encoded.decode("utf-8").encode("utf-16-le")) // 2
    if units >= SITE_UTF16_LIMIT:
        raise ValueError("Still too large for Site (UTF16): " + str(units))
    if load(encoded.decode("utf-8")) != current or len(current["requests"]) != len(before["requests"]):
        raise ValueError("JSON round-trip or request count mismatch")
    return encoded, {"requests": len(current["requests"]), "archived_groupings": len(live_groups),
                     "utf16_units": units, "limit": SITE_UTF16_LIMIT, "archive_commit": ARCHIVE_COMMIT}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    content, report = repair()
    print("TT_IMAGE_INBOX_REQUESTS_CAPACITY " + json.dumps(report))
    if args.apply and SOURCE.read_bytes() != content:
        output = SOURCE.with_name(SOURCE.name + ".capacity.tmp")
        output.write_bytes(content)
        output.replace(SOURCE)
        print("TT_IMAGE_INBOX_REQUESTS_LOSSLESS_ARCHIVED_AND_COMPACTED")
    elif args.apply:
        print("TT_IMAGE_INBOX_REQUESTS_ALREADY_SAFE")
    else:
        print("TT_IMAGE_INBOX_REQUESTS_READ_ONLY_CHECK_OK")


if __name__ == "__main__":
    main()
