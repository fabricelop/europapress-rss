"""Lossless, incremental cold storage for expired Noticias V2 radar events.

Every batch is an immutable JSON document committed atomically with the new
working ledger. A compact identity record stays in current.json to prevent
the same archived stories from being rediscovered by the live radar.
"""
from __future__ import annotations

import base64
import binascii
import copy
import gzip
import hashlib
import json
from datetime import datetime, timedelta, timezone

from .radar_snapshot_v2 import PREFIX, encode, sha256

ARCHIVE_PREFIX = PREFIX + "state/radar/archive/"
MAX_BATCH_ITEMS = 350
MAX_BATCH_BYTES = 2_000_000
MIN_EXPIRED_AGE = timedelta(hours=48)


def _time(value):
    if not isinstance(value, str):
        return None
    try:
        date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return date.astimezone(timezone.utc) if date.tzinfo else None


def _identity(event, batch_id):
    """Keep exact URLs and all known titles, even when evidence is offloaded."""
    appearances = event.get("appearances") or []
    aliases = list(dict.fromkeys(
        str(title) for title in ([event.get("canonical_title")] +
             [a.get("title") for a in appearances] + list(event.get("aliases") or []))
        if title))
    urls = list(dict.fromkeys(
        str(url) for url in ([event.get("canonical_url")] +
             [a.get("canonical_url") or a.get("url") for a in appearances]) if url))
    return {
        "event_id": event["event_id"],
        "canonical_title": event.get("canonical_title") or "",
        "aliases": aliases,
        "canonical_urls": urls,
        "source_families": list(event.get("source_families") or []),
        "status": "archived",
        "terminal_status": "archived",
        "first_seen_at": event.get("first_seen_at"),
        "last_seen_at": event.get("last_seen_at"),
        "archive_batch": batch_id,
    }


def restore_archive(document):
    """Verify a cold-storage checksum and restore EVERY original event field."""
    if document.get("kind") != "expired_radar_archive" or document.get("encoding") != "gzip+base64":
        raise ValueError("RADAR_ARCHIVE_ENCODING_INVALID")
    try:
        packed = base64.b64decode(document["payload_b64"], validate=True)
        raw = gzip.decompress(packed)
        if hashlib.sha256(raw).hexdigest() != document["payload_sha256"]:
            raise ValueError("RADAR_ARCHIVE_CHECKSUM_MISMATCH")
        items = json.loads(raw.decode("utf-8"))["items"]
    except (KeyError, ValueError, OSError, UnicodeError, binascii.Error) as exc:
        raise ValueError("RADAR_ARCHIVE_CORRUPTED") from exc
    if not isinstance(items, dict) or len(items) != document.get("count"):
        raise ValueError("RADAR_ARCHIVE_COUNT_MISMATCH")
    if any(item.get("event_id") != event_id for event_id, item in items.items()):
        raise ValueError("RADAR_ARCHIVE_ID_MISMATCH")
    return items


def archive_expired_events(radar, *, now):
    """Return (compacted_radar, archive_path, archive_document) or no-op.

    Neither inputs nor old archive documents are modified. The caller must
    commit both returned documents in ONE CAS transaction and verify readback.
    """
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("NOW_MUST_BE_TIMEZONE_AWARE")
    cutoff = now.astimezone(timezone.utc) - MIN_EXPIRED_AGE
    original = radar.get("items") or {}
    existing_index = radar.get("archive_index") or {}
    if not isinstance(original, dict) or not isinstance(existing_index, dict):
        raise ValueError("RADAR_ARCHIVE_STRUCTURE_INVALID")
    if set(original) & set(existing_index):
        raise ValueError("RADAR_ARCHIVE_DUPLICATE_ID")
    candidates = sorted((event_id for event_id, event in original.items()
                         if event.get("status") == "archived" and
                         (expired := _time(event.get("expired_at"))) is not None and
                         expired <= cutoff), key=lambda event_id:
                        (original[event_id].get("expired_at", ""), event_id))
    selected = {}
    for event_id in candidates:
        event = original[event_id]
        if event.get("event_id") != event_id:
            raise ValueError("RADAR_ARCHIVE_ID_MISMATCH")
        proposed = {**selected, event_id: event}
        # Avoid large additional GitHub blobs or oversized GraphQL transactions.
        if len(encode({"items": proposed}).encode("utf-8")) > MAX_BATCH_BYTES:
            if not selected:
                raise ValueError("RADAR_ARCHIVE_EVENT_TOO_LARGE")
            break
        selected[event_id] = event
        if len(selected) >= MAX_BATCH_ITEMS:
            break
    if not selected:
        return copy.deepcopy(radar), None, None

    batch_seed = sha256({"items": selected})[:24]
    archive_path = ARCHIVE_PREFIX + "batch-" + batch_seed + ".json"
    raw = encode({"items": selected}).encode("utf-8")
    archive_doc = {"schema_version": 1, "project": "ttittulares-v2",
                   "kind": "expired_radar_archive", "batch_id": batch_seed,
                   "count": len(selected), "encoding": "gzip+base64",
                   "payload_sha256": hashlib.sha256(raw).hexdigest(),
                   "payload_b64": base64.b64encode(gzip.compress(raw, compresslevel=6,
                                                                  mtime=0)).decode("ascii")}
    if restore_archive(archive_doc) != selected:
        raise ValueError("RADAR_ARCHIVE_ROUNDTRIP_MISMATCH")
    result = copy.deepcopy(radar)
    for event_id, event in selected.items():
        del result["items"][event_id]
        result.setdefault("archive_index", {})[event_id] = _identity(event, batch_seed)
    manifest = result.setdefault("archive_manifest", [])
    manifest.append({"path": archive_path, "sha256": sha256(archive_doc),
                     "count": len(selected), "batch_id": batch_seed})
    metrics = result.get("metrics") or {}
    metrics["working_count"] = len(result["items"])
    metrics["cold_archive_count"] = len(result["archive_index"])
    metrics["candidate_count"] = len(result["items"]) + len(result["archive_index"])
    metrics["archived_count"] = (sum(e.get("status") == "archived" for e in result["items"].values())
                                 + len(result["archive_index"]))
    result["metrics"] = metrics
    return result, archive_path, archive_doc
