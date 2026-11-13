"""Explicit user suppression of single trend labels (not generic political terms).

Kept as a small durable source of truth, separate from the very large
historical requests ledger. The ledger is retained for audit.
"""
import json
import unicodedata
from pathlib import Path

CONFIG = Path(__file__).with_name("suppressed-terms.json")


def key(value):
    value = unicodedata.normalize("NFD", str(value or "").casefold().strip().lstrip("#"))
    return "".join(c for c in value if unicodedata.category(c) != "Mn" and not c.isspace())


def suppressed_keys():
    data = json.loads(CONFIG.read_text(encoding="utf-8"))
    return {key(row["key"]) for row in data.get("terms", [])
            if row.get("key") and row.get("do_not_requeue") is True}


def is_suppressed(value, keys=None):
    return key(value) in (suppressed_keys() if keys is None else keys)


def active_request(row, keys=None):
    return is_suppressed(row.get("name"), keys) or is_suppressed(row.get("display_name"), keys)


def purge_pending(requests, keys=None):
    """Terminate all pending revisions without deleting historical evidence."""
    keys = suppressed_keys() if keys is None else keys
    count = 0
    for row in requests:
        if not active_request(row, keys):
            continue
        if str(row.get("status") or "").lower() not in {
            "preparing", "update", "problematic", "ready", "inactive", "pending"
        }:
            continue
        row["status"] = "removed"
        row["inactive_reason"] = "editor_user_suppressed"
        row["reexplain"] = False
        row["with_image"] = False
        row["disable_ai_image"] = True
        row["rewrite_pending"] = False
        count += 1
    return count
