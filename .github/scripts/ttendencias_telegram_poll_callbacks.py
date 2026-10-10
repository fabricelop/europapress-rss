#!/usr/bin/env python3
"""Callback receptor TTendencias bot, sin webhook/Vercel/Cloudflare.
Solo GitHub Actions; verifica chat privado y mensaje/revisión, y no auto-genera IA.
"""
import datetime
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path.cwd()
LEDGER = Path("trends/telegram-image-deliveries.json")
DECISIONS = Path("trends/mobile-decisions.json")
OFFSET = Path("trends/telegram-native-callback-offset.json")
ACKS = Path("/tmp/tt-tr-telegram-callback-acks.json")
PATTERN = re.compile(r"^tx:([bdp]):([A-Za-z0-9_-]{5,80}):(\d{1,8})$")


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def read(path, default):
    try:
        return json.loads((ROOT / path).read_text(encoding="utf8"))
    except FileNotFoundError:
        return default


def write(path, doc):
    dest = ROOT / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf8")


def process(updates, allowed_chat, ledger, decisions, offset):
    changed = False
    acknowledgements = []
    current = int(offset.get("last_update_id") or 0)
    for item in sorted(updates, key=lambda x: int(x.get("update_id") or 0)):
        uid = int(item.get("update_id") or 0)
        if uid <= current:
            continue
        current = uid
        cq = item.get("callback_query") or {}
        match = PATTERN.fullmatch(str(cq.get("data") or ""))
        if not match:
            continue
        msg = cq.get("message") or {}
        chat = msg.get("chat") or {}
        chat_id = str(chat.get("id") or "")
        sender = str((cq.get("from") or {}).get("id") or "")
        if not allowed_chat or chat_id != allowed_chat:
            continue
        if str(chat.get("type") or "") == "private" and sender != chat_id:
            continue
        raw_action, event_id, rev = match.groups()
        rev = int(rev)
        mid = int(msg.get("message_id") or 0)
        matched = [x for x in ledger.get("items", [])
                   if str(x.get("event_id") or "") == event_id
                   and int(x.get("revision") or 0) == rev
                   and mid > 0 and mid in {
                       int(x.get("telegram_message_id") or 0),
                       int(x.get("archive_telegram_message_id") or 0)
                   }]
        status = "published" if raw_action == "p" else "deleted"
        qid = str(cq.get("id") or "")
        if not matched:
            acknowledgements.append({"callback_id": qid,
                                    "text": "No se encontró el paquete exacto; no se borró nada.",
                                    "alert": True})
            continue
        terminal = {"published"} if status == "published" else {"delete_pending", "deleted"}
        already = all(str(x.get("status") or "") in terminal for x in matched)
        if not already:
            for row in matched:
                row["status"] = "published" if status == "published" else "delete_pending"
                row["decision_source"] = "telegram_bot_native_poll"
                row["updated_at"] = stamp()
                if status == "published":
                    row["published_at"] = stamp()
            ledger["updated_at"] = stamp()
            changed = True
        record = next((x for x in decisions.get("items", [])
                       if str(x.get("id") or "") == event_id), None)
        if record is None:
            record = {"id": event_id}
            decisions.setdefault("items", []).append(record)
            changed = True
        if record.get("status") != status or int(record.get("revision") or -1) != rev:
            record.update(status=status, revision=rev,
                          updated_at=stamp(), source="telegram_bot_native_poll")
            decisions["updated_at"] = stamp()
            changed = True
        acknowledgements.append({"callback_id": qid,
             "text": ("Publicada." if status == "published"
                      else "Borrado registrado. El mensaje desaparecerá al procesarse."),
             "alert": False})
    if current != int(offset.get("last_update_id") or 0):
        offset["last_update_id"] = current
        offset["updated_at"] = stamp()
        changed = True
    return changed, acknowledgements


def request_json(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "TTendencias-GitHub-Callback/1.0",
        "Content-Type": "application/json"
    })
    with urllib.request.urlopen(req, timeout=25) as response:
        return json.load(response)


def live():
    token = os.environ.get("TTENDENCIAS_BOT_TOKEN", "").strip()
    if not token:
        raise RuntimeError("TTENDENCIAS_BOT_TOKEN no configurado")
    state = read("trends/telegram-bot-state.json", {})
    chat = os.environ.get("TTENDENCIAS_CHAT_ID", "").strip() or str(state.get("chat_id") or "")
    if not chat:
        raise RuntimeError("TTENDENCIAS_CHAT_ID no disponible")
    offset = read(OFFSET, {"version": 1, "last_update_id": 0})
    ledger = read(LEDGER, {"items": []})
    decisions = read(DECISIONS, {"items": []})
    params = urllib.parse.urlencode({
        "offset": int(offset.get("last_update_id") or 0) + 1,
        "limit": 100, "timeout": 0,
        "allowed_updates": json.dumps(["callback_query"])
    })
    base = "https://api.telegram.org/bot" + token + "/"
    result = request_json(base + "getUpdates?" + params)
    if not result.get("ok"):
        raise RuntimeError("Telegram getUpdates no respondió correctamente")
    updates = result.get("result") or []
    changed, acks = process(updates, chat, ledger, decisions, offset)
    if changed:
        write(LEDGER, ledger)
        write(DECISIONS, decisions)
        write(OFFSET, offset)
    ACKS.write_text(json.dumps(acks, ensure_ascii=False), encoding="utf8")
    print("TTENDENCIAS_TELEGRAM_CALLBACKS", json.dumps({
        "received": len(updates), "acknowledge": len(acks),
        "changed": changed, "last_update_id": offset.get("last_update_id")
    }))
    # GitHub Actions acknowledges callbacks only after a successful git push.
    return changed


def selftest():
    ledger = {"items":[{"event_id":"abc123xyz","revision":2,
        "telegram_message_id":1234,"status":"sent"}]}
    decisions = {"items":[]}
    state = {"last_update_id":0}
    update = {"update_id":100,"callback_query":{"id":"testcallback123",
        "data":"tx:b:abc123xyz:2","from":{"id":456},
        "message":{"message_id":1234,"chat":{"id":456,"type":"private"}}}}
    changed, acks = process([update], "456", ledger, decisions, state)
    assert changed and len(acks) == 1
    assert ledger["items"][0]["status"] == "delete_pending"
    assert decisions["items"][0]["status"] == "deleted"
    assert state["last_update_id"] == 100
    changed2, _ = process([update], "456", ledger, decisions, state)
    assert not changed2
    bad = {"update_id":101,"callback_query":{"id":"badcallback321",
        "data":"tx:b:abc123xyz:2","from":{"id":999},
        "message":{"message_id":1234,"chat":{"id":999,"type":"private"}}}}
    process([bad], "456", ledger, decisions, state)
    assert ledger["items"][0]["status"] == "delete_pending"
    print("TTENDENCIAS_TELEGRAM_CALLBACK_SELFTEST_OK")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        selftest()
    else:
        live()
