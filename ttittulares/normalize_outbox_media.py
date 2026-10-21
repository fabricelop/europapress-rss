#!/usr/bin/env python3
"""Normalize legacy optional photo URLs in editorial outboxes before READY apply.

Text and the source editorial result are untouched. No network access or images
are required. This is idempotent so the job can safely retry after conflicts.
"""
import json
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

OUTBOX = Path(__file__).resolve().parent / "editorial-outbox"


def normalize(doc):
    if not isinstance(doc, dict) or doc.get("status") != "ready":
        return False
    item = doc.get("prepared_item")
    if not isinstance(item, dict):
        return False
    changed = False
    for key in ("archive_image", "fallback_image"):
        raw = item.get(key)
        if not isinstance(raw, str):
            continue
        url = raw.strip()
        if url.startswith("https://") and urlparse(url).hostname:
            item[key] = {
                "url": url,
                "source": urlparse(url).hostname,
                "source_url": str(item.get("url") or ""),
                "rights_status": "unverified",
                "generated": False,
                "alt": str(item.get("title") or "Fotografía de archivo"),
            }
        else:
            item.pop(key, None)
            item[key + "_status"] = "none"
            item[key + "_failure_reason"] = "URL de fotografía no válida; texto editorial conservado"
        changed = True
    return changed


def apply(folder):
    total = 0
    for path in sorted(folder.glob("*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        if normalize(doc):
            path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            total += 1
            print("OPTIONAL_ARCHIVE_IMAGE_NORMALIZED", path.name)
    return total


def selftest():
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "1759943d83c8-r1.json"
        original = {"event_id": "1759943d83c8", "revision": 1, "status": "ready",
                    "prepared_item": {
                        "title": "Prueba", "tweet": {"text": "No alterar"},
                        "fallback_image": "https://example.org/photo.jpg",
                        "archive_image": "https://example.org/photo.jpg",
                        "fallback_image_status": "ready",
                    }}
        path.write_text(json.dumps(original), encoding="utf-8")
        assert apply(Path(d)) == 1
        fixed = json.loads(path.read_text(encoding="utf-8"))
        assert isinstance(fixed["prepared_item"]["archive_image"], dict)
        assert isinstance(fixed["prepared_item"]["fallback_image"], dict)
        assert fixed["prepared_item"]["tweet"] == original["prepared_item"]["tweet"]
        assert apply(Path(d)) == 0
    print("TTI_OPTIONAL_ARCHIVE_NORMALIZATION_SELFTEST_OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        print("TTI_OPTIONAL_ARCHIVES_CHANGED", apply(OUTBOX))
