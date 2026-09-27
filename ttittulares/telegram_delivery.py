#!/usr/bin/env python3
"""Entrega aislada de imágenes editoriales a Telegram desde un comentario del PR #2.

El raster vive únicamente en el evento de GitHub Actions. En el repositorio se
persisten solo los identificadores de los mensajes y el estado de entrega.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import re
import sys
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PREPARED = ROOT / "ttittulares/prepared.json"
DECISIONS = ROOT / "ttittulares/decisions.json"
RECEIPT = Path("/tmp/ttittulares-telegram-receipt.json")
IMAGE_PREFIX = "TTITTULARES_TELEGRAM_IMAGE_V1\n"
ERROR_PREFIX = "TTITTULARES_TELEGRAM_IMAGE_ERROR_V1\n"
EVENT_ID = re.compile(r"^[A-Za-z0-9_-]{4,80}$")
ERROR_CODE = re.compile(r"^[a-z][a-z0-9_]{2,79}$")
APP_URL = "https://europapress-rss.vercel.app/ttittulares/"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def telegram(method, fields, photo=None):
    token = os.environ["TELEGRAM_BOT_TOKEN"]
    if photo is None:
        body = json.dumps(fields, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
    else:
        boundary = "----ttittulares" + uuid.uuid4().hex
        pieces = []
        for name, value in fields.items():
            if not isinstance(value, str):
                value = json.dumps(value, ensure_ascii=False)
            pieces.append((f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n').encode())
        pieces.extend([(f'--{boundary}\r\nContent-Disposition: form-data; name="photo"; filename="gag.jpg"\r\nContent-Type: image/jpeg\r\n\r\n').encode(), photo, f"\r\n--{boundary}--\r\n".encode()])
        body = b"".join(pieces)
        headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
    req = urllib.request.Request(f"https://api.telegram.org/bot{token}/{method}", data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=35) as response:
        result = json.load(response)
    if not result.get("ok"):
        raise RuntimeError(f"Telegram {method}: {result.get('description', 'respuesta no válida')}")
    return result["result"]


def payload_from_event():
    event = load(Path(os.environ["GITHUB_EVENT_PATH"]))
    if (event.get("repository") or {}).get("full_name") != "fabricelop/europapress-rss":
        raise ValueError("repositorio inesperado")
    issue, comment = event.get("issue") or {}, event.get("comment") or {}
    if issue.get("number") != 2 or not issue.get("pull_request"):
        raise ValueError("no es PR #2")
    if (comment.get("user") or {}).get("login") != "fabricelop":
        raise ValueError("autor no autorizado")
    body = comment.get("body") or ""
    if body.startswith(IMAGE_PREFIX):
        kind, raw = "image", body[len(IMAGE_PREFIX):]
    elif body.startswith(ERROR_PREFIX):
        kind, raw = "error", body[len(ERROR_PREFIX):]
    else:
        raise ValueError("prefijo desconocido")
    data = json.loads(raw)
    if not isinstance(data, dict) or not EVENT_ID.fullmatch(str(data.get("event_id") or "")):
        raise ValueError("event_id inválido")
    return kind, data


def visible_item(event_id, revision):
    decisions = load(DECISIONS)
    if any(str(x.get("event_id")) == event_id and str(x.get("status", "")).lower() in {"published", "dismissed"} for x in decisions.get("items", [])):
        return None
    prepared = load(PREPARED)
    return next((x for x in prepared.get("items", []) if str(x.get("event_id")) == event_id and int(x.get("revision") or 1) == revision and not x.get("image_cancelled_by_publication")), None)


def verify_image(data):
    encoded = data.get("image_base64")
    if not isinstance(encoded, str):
        raise ValueError("faltan bytes de imagen")
    raster = base64.b64decode(encoded, validate=True)
    if not 4096 <= len(raster) <= 40000:
        raise ValueError("JPEG fuera del límite de 4–40 KB")
    if hashlib.sha256(raster).hexdigest() != data.get("sha256"):
        raise ValueError("sha256 del raster no coincide")
    with Image.open(io.BytesIO(raster)) as im:
        im.verify()
    with Image.open(io.BytesIO(raster)) as im:
        if im.format != "JPEG" or im.width < 600 or im.height < 360 or im.width < im.height:
            raise ValueError("raster JPEG no válido para TTiTTulares")
        im.load()
    return raster


def send_image(data):
    event_id = str(data["event_id"])
    revision = int(data.get("revision") or 1)
    if revision < 1:
        raise ValueError("revisión inválida")
    item = visible_item(event_id, revision)
    if item is None:
        print("SKIPPED_STALE", event_id)
        return
    if item.get("image_status") == "telegram" and item.get("image_telegram_delivered"):
        print("ALREADY_DELIVERED", event_id)
        return
    if item.get("image_status") == "ready" and (item.get("image") or {}).get("url"):
        print("ALREADY_READY_IN_APP", event_id)
        return
    raster = verify_image(data)
    title = str(item.get("title") or "Noticia TTiTTulares").strip()[:4096]
    chat = os.environ["TELEGRAM_CHAT_ID"]
    headline = telegram("sendMessage", {"chat_id": chat, "text": title, "disable_web_page_preview": True})
    headline_id = headline["message_id"]
    query = f"view=ready&event_id={event_id}"
    keyboard = {"inline_keyboard": [
        [{"text": "📱 Abrir noticia en app", "url": f"{APP_URL}?{query}"}],
        [{"text": "🗑️ Borrar titular + foto", "callback_data": f"dg:{headline_id}"}],
    ]}
    try:
        photo = telegram("sendPhoto", {"chat_id": chat, "reply_markup": keyboard}, photo=raster)
    except Exception:
        telegram("deleteMessage", {"chat_id": chat, "message_id": headline_id})
        raise
    receipt = {
        "event_id": event_id, "revision": revision, "headline_id": headline_id,
        "photo_id": photo["message_id"], "sha256": data["sha256"],
        "delivered_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    RECEIPT.write_text(json.dumps(receipt), encoding="utf-8")
    print("TELEGRAM_IMAGE_SENT", event_id, "headline_id=" + str(headline_id), "photo_id=" + str(photo["message_id"]), "bytes=" + str(len(raster)))


def send_error(data):
    event_id = str(data["event_id"])
    code = str(data.get("error_code") or "")
    if not ERROR_CODE.fullmatch(code):
        raise ValueError("error_code inválido")
    revision = int(data.get("revision") or 1)
    item = visible_item(event_id, revision)
    if item is None:
        print("SKIPPED_STALE_ERROR", event_id)
        return
    explanation = str(data.get("explanation") or "sin explicación").strip()[:1200]
    title = str(item.get("title") or "Noticia TTiTTulares")[:300]
    message = f"TTiTTulares · fallo de imagen IA\n{title}\nEvento: {event_id} · revisión: {revision}\nCódigo: {code}\nDetalle: {explanation}\nSe intentará imagen de archivo."
    result = telegram("sendMessage", {"chat_id": os.environ["TELEGRAM_CHAT_ID"], "text": message, "disable_web_page_preview": True})
    print("TELEGRAM_IMAGE_ERROR_SENT", event_id, code, "message_id=" + str(result["message_id"]))


def apply_receipt():
    receipt = load(RECEIPT)
    event_id, revision = receipt["event_id"], receipt["revision"]
    doc = load(PREPARED)
    item = next((x for x in doc.get("items", []) if str(x.get("event_id")) == event_id and int(x.get("revision") or 1) == revision), None)
    if item is None:
        raise RuntimeError("La noticia desapareció de Listas después del envío")
    if item.get("image_status") == "telegram" and item.get("image_telegram_message_id") == receipt["photo_id"]:
        return
    if visible_item(event_id, revision) is None:
        raise RuntimeError("La noticia se cerró después del envío; revisar y retirar los mensajes")
    item.update({
        "image_status": "telegram", "image_delivery": "telegram", "image_app_available": False,
        "image_pending": False, "image_telegram_delivered": True,
        "image_telegram_headline_message_id": receipt["headline_id"],
        "image_telegram_message_id": receipt["photo_id"],
        "image_telegram_delivered_at": receipt["delivered_at"],
        "image_telegram_sha256": receipt["sha256"],
    })
    item.pop("image", None)
    item.pop("image_failure_reason", None)
    doc["updated_at"] = receipt["delivered_at"]
    PREPARED.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "apply-receipt":
        apply_receipt()
        return
    kind, data = payload_from_event()
    if kind == "image":
        send_image(data)
    else:
        send_error(data)


if __name__ == "__main__":
    main()
