#!/usr/bin/env python3
"""Materializa un único intento IA y lo adjunta a una noticia READY.

Este consumidor es deliberadamente independiente del outbox editorial:
un fallo de imagen nunca cambia el texto, el tuit ni el estado READY.
"""
from __future__ import annotations
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from apply_editorial_outbox import TT, PREP, DECISIONS, load, save, _materialize_ai_image, _select_image

OUTBOX = TT / "image-outbox"


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def selftest():
    import base64, io
    from PIL import Image
    im=Image.new("RGB",(640,360))
    px=im.load()
    for y in range(360):
        for x in range(640):
            px[x,y]=((x*3+y)%256,(y*5+x//2)%256,(x+y*2)%256)
    raw=io.BytesIO();im.save(raw,format="JPEG",quality=88)
    data=base64.b64encode(raw.getvalue()).decode("ascii")
    item={
        "event_id":"selftest-ai","revision":1,"title":"Selftest",
        "ai_image_attempt":1,
        "ai_image":{
            "url":"data:image/jpeg;base64,"+data,
            "source":"TTiTTulares / ChatGPT ImageGen","rights_status":"generated","generated":True,
            "provider":"chat-imagegen","origin":"executing_chat",
            "generation_attempt":1,
            "context_guard":{"version":3,"event_id":"selftest-ai","revision":1,"scope":"current_item_only"},
        },
    }
    assert _materialize_ai_image(item)
    url=item["ai_image"]["url"]
    assert url.endswith("/ttittulares/generated-images/selftest-ai-r1-ai1.jpg")
    path=TT/"generated-images"/"selftest-ai-r1-ai1.jpg"
    assert path.is_file() and path.stat().st_size>4096
    path.unlink()
    rejected={**item,"ai_image":dict(item["ai_image"],provider="chat-svg")}
    try:
        _materialize_ai_image(rejected)
    except ValueError as exc:
        assert "provider" in str(exc)
    else:
        raise AssertionError("chat-svg no puede aceptarse como ai_image")
    print("TTITTULARES_AI_IMAGE_SELFTEST_OK")
    return 0


def main():
    doc = load(PREP, {"project": "TTiTTulares", "items": []})
    decisions = load(DECISIONS, {"items": []})
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
            terminal = next((x for x in reversed(decisions.get("items", []))
                             if str(x.get("event_id") or "") == eid
                             and str(x.get("status") or "").lower() in {"published","dismissed"}), None)
            if terminal:
                path.unlink(missing_ok=True)
                processed.append(eid + ":cancelled")
                changed = True
                continue
            waiting.append(path.name)
            continue

        current_attempt = int(item.get("ai_image_attempt") or 0)
        expected_attempt = current_attempt or 1
        if attempt != expected_attempt:
            path.unlink(missing_ok=True)
            processed.append(eid + ":attempt-mismatch")
            changed = True
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
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    raise SystemExit(main())
