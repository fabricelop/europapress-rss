#!/usr/bin/env python3
"""Send only validated TTiTTulares AI images to the configured Telegram chat."""
import hashlib
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PREP = ROOT / "ttittulares/prepared.json"
LEDGER = ROOT / "telegram/tt-ai-image-deliveries.json"
PREFIX = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/"

def read(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default

def eligible(item, decided):
    eid = str(item.get("event_id") or "")
    if not re.fullmatch(r"[a-f0-9]{12}", eid) or eid in decided:
        return None
    ai = item.get("ai_image") or {}
    guard = ai.get("context_guard") or {}
    if (item.get("ai_image_status") != "ready" or
        ai.get("provider") != "chat-imagegen" or
        ai.get("origin") != "executing_chat" or
        ai.get("generated") is not True or
        guard.get("version") != 3 or guard.get("scope") != "current_item_only" or
        guard.get("event_id") != eid or
        int(guard.get("revision") or 0) != int(item.get("revision") or 1)):
        return None
    url = str(ai.get("url") or "")
    filename = url.removeprefix(PREFIX)
    if not url.startswith(PREFIX) or not re.fullmatch(r"[a-f0-9]{12}-r\d+-ai\d+\.jpe?g", filename):
        return None
    photo = ROOT / "ttittulares/generated-images" / filename
    if not photo.is_file():
        return None
    data = photo.read_bytes()
    if not (data.startswith(b"\xff\xd8\xff") and 4096 < len(data) < 10_000_000):
        return None
    if hashlib.sha256(data).hexdigest() != str(ai.get("sha256") or "").lower():
        return None
    return data

def send(token, chat_id, image, caption):
    boundary = "ttai-" + hashlib.sha256(image).hexdigest()[:24]
    def field(name, value):
        return (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").encode()
    body = (field("chat_id", chat_id) + field("caption", caption) +
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"imagen.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".encode() +
            image + f"\r\n--{boundary}--\r\n".encode())
    req = urllib.request.Request("https://api.telegram.org/bot" + token + "/sendPhoto",
                                 data=body, headers={"Content-Type": "multipart/form-data; boundary=" + boundary}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=35) as response:
            result = json.loads(response.read())
    except Exception as exc:
        raise RuntimeError("Telegram no confirmó sendPhoto: " + type(exc).__name__) from None
    if not result.get("ok") or not (result.get("result") or {}).get("message_id"):
        raise RuntimeError("Telegram no confirmó message_id")
    return int(result["result"]["message_id"])

def main():
    token, chat_id = os.getenv("TELEGRAM_BOT_TOKEN", ""), os.getenv("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        raise RuntimeError("Faltan TELEGRAM_BOT_TOKEN o TELEGRAM_CHAT_ID")
    ledger = read(LEDGER, {"version": 1, "items": []})
    decided = {str(x.get("event_id") or "") for x in read(ROOT / "ttittulares/decisions.json", {"items": []})["items"]
               if str(x.get("status") or "").lower() in {"deleted", "dismissed", "published"}}
    sent = {(str(x.get("event_id")), int(x.get("revision") or 1), str(x.get("sha256")))
            for x in ledger["items"] if x.get("status") == "sent"}
    for item in read(PREP, {"items": []})["items"]:
        ai = item.get("ai_image") or {}
        key = (str(item.get("event_id")), int(item.get("revision") or 1), str(ai.get("sha256")))
        if key in sent:
            continue
        image = eligible(item, decided)
        if image is None:
            continue
        caption = "Imagen IA · " + str(item.get("title") or "TTiTTulares")[:400]
        message_id = send(token, chat_id, image, caption)
        ledger["items"].append({"event_id": key[0], "revision": key[1], "sha256": key[2],
                                "telegram_message_id": message_id, "status": "sent",
                                "sent_at": datetime.now(timezone.utc).isoformat()})
        sent.add(key)
        LEDGER.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("TT_AI_IMAGE_SENT", key[0], message_id)
    print("TT_AI_IMAGE_DELIVERIES", len(sent))

if __name__ == "__main__":
    main()
