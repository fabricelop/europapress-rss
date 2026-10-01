#!/usr/bin/env python3
"""Materializa un único intento IA y lo adjunta a una noticia READY.

Este consumidor es deliberadamente independiente del outbox editorial:
un fallo de imagen nunca cambia el texto, el tuit ni el estado READY.
"""
from __future__ import annotations
import json
from datetime import datetime, timezone
from pathlib import Path

from apply_editorial_outbox import TT, PREP, load, save, _materialize_ai_image, _select_image

OUTBOX = TT / "image-outbox"


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def main():
    doc = load(PREP, {"project": "TTiTTulares", "items": []})
    files = sorted(OUTBOX.glob("*.json")) if OUTBOX.exists() else []
    if not files:
        print("TTITTULARES_AI_IMAGE_OUTBOX_EMPTY")
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
        eid = str(payload.get("event_id") or "").strip()
        revision = int(payload.get("revision") or 1)
        attempt = max(1, int(payload.get("attempt") or 1))
        item = next((x for x in doc.get("items", [])
                     if str(x.get("event_id") or "") == eid
                     and int(x.get("revision") or 1) == revision), None)
        if item is None:
            waiting.append(path.name)
            continue

        status = str(payload.get("status") or "").lower()
        previous_ai = dict(item.get("ai_image") or {})
        if status == "ready" and isinstance(payload.get("ai_image"), dict):
            holder = {
                "event_id": eid,
                "revision": revision,
                "title": item.get("title") or "",
                "ai_image": dict(payload["ai_image"]),
                "ai_image_attempt": attempt,
            }
            try:
                _materialize_ai_image(holder)
                item["ai_image"] = holder["ai_image"]
                item["ai_image_status"] = "ready"
                item["ai_image_attempt"] = attempt
                item["ai_image_last_attempt_status"] = "ready"
                item["ai_image_last_attempt_at"] = now()
                item.pop("ai_image_failure_reason", None)
                item.pop("ai_image_regeneration_error", None)
                item["image_choice"] = "ai"
                item["image"] = dict(holder["ai_image"])
                item["image_status"] = "ready"
                item["image_pending"] = False
                item["image_app_available"] = True
                item["image_delivery"] = "app"
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
                _select_image(item)

        item.pop("ai_image_regenerate_requested", None)
        item.pop("ai_image_regenerate_requested_at", None)
        item.pop("ai_image_regenerate_request_version", None)
        path.unlink(missing_ok=True)
        processed.append(eid)
        changed = True

    if changed:
        doc["updated_at"] = now()
        save(PREP, doc)
    print(json.dumps({"processed": processed, "waiting": waiting}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
