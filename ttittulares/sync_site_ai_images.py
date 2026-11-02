#!/usr/bin/env python3
"""Mirror verified TTiTTulares ImageGen rasters into the app/web image catalog.

This is a *materialized-image* bridge, not a Telegram/TTImages downloader:
a Telegram photo receipt alone is never proof that GitHub holds the original.
Safe to rerun after every READY editorial update. Existing manual associations
remain untouched, and photos of archive are never altered.
"""
from __future__ import annotations
import hashlib
import json
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PREPARED = ROOT / "ttittulares/prepared.json"
MANIFEST = ROOT / "ttittulares/site-ai-images.json"
GENERATED = ROOT / "ttittulares/generated-images"
PREFIX = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
ID = re.compile(r"^[A-Za-z0-9_-]{3,160}$")
SHA = re.compile(r"^[0-9a-f]{64}$", re.I)
FILE = re.compile(r"^[A-Za-z0-9_-]+-r[0-9]+-ai[0-9]+(?:-[A-Za-z0-9_-]+)?\.(?:png|jpe?g|webp)$", re.I)


def from_ready(item: dict[str, Any], root: Path = ROOT) -> dict | None:
    event_id = str(item.get("event_id") or "")
    revision = int(item.get("revision") or 0)
    if not ID.fullmatch(event_id) or revision < 1 or item.get("rewrite_pending"):
        return None
    if str(item.get("ai_image_status") or "").lower() != "ready":
        return None
    ai = item.get("ai_image")
    if not isinstance(ai, dict) or ai.get("generated") is not True or ai.get("provider") != "chat-imagegen":
        return None
    sha = str(ai.get("sha256") or "").lower()
    url = str(ai.get("url") or "")
    if not SHA.fullmatch(sha) or not url.startswith(PREFIX + "ttittulares/generated-images/"):
        return None
    filename = url.rsplit("/", 1)[-1]
    if not FILE.fullmatch(filename) or not filename.startswith(f"{event_id}-r{revision}-ai"):
        return None
    guard = ai.get("context_guard")
    if isinstance(guard, dict) and (guard.get("event_id") != event_id or
                                    int(guard.get("revision") or 0) != revision):
        return None
    path = root / "ttittulares/generated-images" / filename
    if not path.is_file():
        return None
    if hashlib.sha256(path.read_bytes()).hexdigest() != sha:
        return None
    prepared_at = str(item.get("prepared_at") or "")
    tweet = item.get("tweet") if isinstance(item.get("tweet"), dict) else {}
    editorial_text = str(tweet.get("text") or "")
    if not prepared_at or not editorial_text:
        return None
    return {
        "target_id": event_id,
        "revision": revision,
        "prepared_at": prepared_at,
        "editorial_text": editorial_text,
        "image_url": url,
        "sha256": sha,
    }


def sync(prepared: dict, manifest: dict, root: Path = ROOT) -> tuple[dict, int]:
    if (manifest.get("schema_version") != 1 or
            manifest.get("project") != "ttittulares" or
            not isinstance(manifest.get("images"), list)):
        raise ValueError("Manifiesto IA inválido: no modificar")
    images = list(manifest["images"])
    seen = {
        (row.get("target_id"), int(row.get("revision") or 0))
        for row in images if isinstance(row, dict)
    }
    added = 0
    for item in prepared.get("items") or []:
        if not isinstance(item, dict):
            continue
        row = from_ready(item, root)
        if row is None:
            continue
        key = (row["target_id"], row["revision"])
        if key in seen:
            # Never replace a prior verified original from another workflow.
            continue
        images.append(row)
        seen.add(key)
        added += 1
    return {**manifest, "images": images}, added


def main() -> int:
    prepared = json.loads(PREPARED.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    updated, count = sync(prepared, manifest)
    if count:
        MANIFEST.write_text(
            json.dumps(updated, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"TTITTULARES_AI_MANIFEST_SYNC added={count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
