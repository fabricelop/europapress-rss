#!/usr/bin/env python3
"""Materializa un intento IA de TTendencias sin tocar el estado editorial."""
from __future__ import annotations
import json
from datetime import datetime, timezone
from pathlib import Path

from apply_editorial_outbox import (
    TRENDS, load, save, validate_generated_image, materialize_inline_generated_image
)

OUTBOX = TRENDS / "image-outbox"
EXPLAINED = TRENDS / "telegram-manual-explained.json"


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def main():
    doc = load(EXPLAINED, {"project": "TTendencias", "items": []})
    files = sorted(OUTBOX.glob("*.json")) if OUTBOX.exists() else []
    if not files:
        print("TTENDENCIAS_AI_IMAGE_OUTBOX_EMPTY")
        return 0

    changed = False
    processed = []
    waiting = []
    for path in files:
        payload = load(path, None)
        if not isinstance(payload, dict):
            path.unlink(missing_ok=True)
            changed = True
            continue
        tid = str(payload.get("id") or "").strip()
        revision = int(payload.get("revision") or 0)
        attempt = max(1, int(payload.get("attempt") or 1))
        # Elegir la explicación más reciente de esa revisión.
        item = next((x for x in reversed(doc.get("items", []))
                     if str(x.get("id") or "") == tid
                     and int(x.get("revision") or 0) == revision), None)
        if item is None:
            waiting.append(path.name)
            continue

        previous_ai = dict(item.get("ai_image") or {})
        status = str(payload.get("status") or "").lower()
        if status == "ready" and isinstance(payload.get("ai_image"), dict):
            holder = {"image": dict(payload["ai_image"])}
            holder["image"]["generation_attempt"] = attempt
            try:
                validate_generated_image(holder, tid, revision)
                materialize_inline_generated_image(holder, tid, revision)
                validate_generated_image(holder, tid, revision)
                ai = holder["image"]
                item["ai_image"] = ai
                item["ai_image_status"] = "ready"
                item["ai_image_attempt"] = attempt
                item["ai_image_last_attempt_status"] = "ready"
                item["ai_image_last_attempt_at"] = now()
                item.pop("ai_image_failure_reason", None)
                item.pop("ai_image_regeneration_error", None)
                item["image"] = dict(ai)
                item["image_choice"] = "ai"
                item["image_status"] = "ready"
                item["image_pending"] = False
            except Exception as exc:
                status = "failed"
                payload["reason"] = str(exc)[:500]

        if status == "failed":
            reason = str(payload.get("reason") or "No se pudo materializar la imagen IA.")[:500]
            item["ai_image_attempt"] = attempt
            item["ai_image_last_attempt_status"] = "failed"
            item["ai_image_last_attempt_at"] = now()
            if previous_ai.get("url"):
                item["ai_image"] = previous_ai
                item["ai_image_status"] = "ready"
                item["ai_image_regeneration_error"] = reason
            else:
                item.pop("ai_image", None)
                item["ai_image_status"] = "failed"
                item["ai_image_failure_reason"] = reason
                fallback = item.get("fallback_image") or {}
                if str(fallback.get("url") or "").startswith("https://"):
                    item["image"] = dict(fallback)
                    item["image_choice"] = "fallback"
                    item["image_status"] = "ready"
                    item["image_pending"] = False
                elif not (item.get("image") or {}).get("url"):
                    item["image_choice"] = "none"
                    item["image_status"] = "none"
                    item["image_pending"] = False

        item.pop("ai_image_regenerate_requested", None)
        item.pop("ai_image_regenerate_requested_at", None)
        item.pop("ai_image_regenerate_request_version", None)
        path.unlink(missing_ok=True)
        processed.append(tid)
        changed = True

    if changed:
        doc["updated_at"] = now()
        save(EXPLAINED, doc)
    print(json.dumps({"processed": processed, "waiting": waiting}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
