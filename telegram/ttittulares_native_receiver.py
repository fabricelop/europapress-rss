#!/usr/bin/env python3
"""GitHub-native Telegram transport for TTiTTulares (safe pre-cutover).

Never deletes/replaces a webhook on its own. The receiver refuses to poll while
a webhook is active: this is essential to preserve the existing Q&A service.
"""
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = "fabricelop/europapress-rss"
STATE = Path("telegram/ttittulares-native-offset.json")
INBOX = Path("telegram/ttittulares-callback-inbox.json")
PROPOSALS = Path("telegram/ttittulares-user-proposals.json")
DELIVERIES = Path("telegram/ttittulares-deliveries.json")
CONTROL_BRANCH = "control/ttittulares-run-trigger-v2"
CONTROL_FILE = "ttittulares/run-now-trigger.json"
CALLBACK = re.compile(r"^tt:([pdb]):([A-Za-z0-9_-]{5,80})$")


def stamp():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def read(path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return fallback


def save(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def classify(update, chat_id, ledger):
    """No side effects. Validate user + delivered exact message, not just ID."""
    callback = update.get("callback_query") or {}
    msg = callback.get("message") if callback else update.get("message")
    msg = msg or {}
    chat = msg.get("chat") or {}
    sender = callback.get("from") if callback else msg.get("from")
    sender = sender or {}
    if (str(chat.get("id") or "") != str(chat_id)
            or str(sender.get("id") or "") != str(chat_id)
            or str(chat.get("type") or "") != "private"):
        return {"kind": "ignore"}
    if callback:
        raw = str(callback.get("data") or "")
        match = CALLBACK.fullmatch(raw)
        if not match:
            return {"kind": "unsupported_callback"}
        action, eid = match.groups()
        mid = int(msg.get("message_id") or 0)
        linked = any(str(x.get("event_id") or "") == eid and
                     str(x.get("status") or "").lower() == "sent" and mid > 0 and
                     mid in (int(x.get("telegram_message_id") or 0),
                             int(x.get("archive_telegram_message_id") or 0),
                             int(x.get("cross_quote_message_id") or 0))
                     for x in ledger.get("items", []))
        if not linked:
            return {"kind": "not_active", "callback_id": callback.get("id")}
        return {"kind": "decision", "action": action, "event_id": eid,
                "message_id": mid, "callback_id": callback.get("id")}
    text = str(msg.get("text") or "").strip()
    if re.fullmatch(r"/run(?:@ttittulares_bot)?", text, re.I):
        return {"kind": "run"}
    if text.startswith("/") or msg.get("reply_to_message"):
        # Chat, questions and reply workflows must be migrated before cutover.
        return {"kind": "requires_conversation_migration"}
    if text:
        return {"kind": "proposal", "text": text[:3000]}
    return {"kind": "ignore"}


def github_call(url, token, payload=None, method="GET"):
    headers = {"Authorization": "Bearer " + token,
               "Accept": "application/vnd.github+json",
               "Content-Type": "application/json",
               "User-Agent": "ttittulares-native-telegram"}
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=25) as res:
        return json.loads(res.read().decode("utf-8"))


def request_editorial(token):
    base = f"https://api.github.com/repos/{REPO}/contents/{CONTROL_FILE}"
    for i in range(5):
        previous = github_call(base + "?ref=" + urllib.parse.quote(CONTROL_BRANCH, safe=""), token)
        doc = json.loads(base64.b64decode(previous["content"]).decode("utf-8"))
        try:
            age = (dt.datetime.now(dt.timezone.utc)
                   - dt.datetime.fromisoformat(str(doc.get("requested_at") or "").replace("Z", "+00:00"))).total_seconds()
        except (ValueError, TypeError):
            age = 999
        if 0 <= age < 90 and doc.get("command_id"):
            return doc["command_id"], True
        command = "tt-" + str(int(time.time() * 1000)) + "-tg-native"
        new = {"version": 2, "command_id": command, "requested_at": stamp(),
               "mode": "manual_pc_chat", "executor": "pc_chat_ttittulares_dedicated",
               "project": "ttittulares", "launcher_arg": "titulares",
               "task": "editorial", "auto_image_followup": False}
        payload = {"branch": CONTROL_BRANCH, "sha": previous["sha"],
                   "message": "TTiTTulares: /run nativo Telegram " + command,
                   "content": base64.b64encode((json.dumps(new, ensure_ascii=False, indent=2) + "\n").encode()).decode()}
        try:
            github_call(base, token, payload, "PUT")
            return command, False
        except urllib.error.HTTPError as e:
            if e.code not in (409, 422) or i == 4:
                raise
            time.sleep((i + 1) * 0.3)
    raise RuntimeError("No se pudo persistir /run")


def telegram_call(token, method, payload):
    url = "https://api.telegram.org/bot" + token + "/" + method
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=40) as res:
        out = json.loads(res.read().decode("utf-8"))
    if not out.get("ok"):
        raise RuntimeError("Telegram " + method + " did not confirm success")
    return out.get("result")


def commit_event(update, act):
    """Merge against fresh main; write offset and action atomically per update."""
    uid = int(update["update_id"])
    for attempt in range(5):
        subprocess.run(["git", "fetch", "origin", "main"], check=True,
                       stdout=subprocess.DEVNULL)
        subprocess.run(["git", "reset", "--hard", "origin/main"], check=True,
                       stdout=subprocess.DEVNULL)
        state = read(STATE, {"version": 1, "last_update_id": 0})
        if uid <= int(state.get("last_update_id") or 0):
            return False
        touched = [str(STATE)]
        if act["kind"] == "decision":
            inbox = read(INBOX, {"version": 1, "requests": []})
            if not any(int(x.get("update_id") or 0) == uid for x in inbox.get("requests", [])):
                inbox.setdefault("requests", []).append({
                    "update_id": uid, "type": "emergency_action",
                    "text": {"p": "ttp", "d": "ttd", "b": "ttb"}[act["action"]] + "|" + act["event_id"],
                    "source": "ttittulares_native_telegram_v1",
                    "verified_by_telegram": True, "verified_at": stamp(),
                    "message_id": act["message_id"]})
                inbox["updated_at"] = stamp()
                save(INBOX, inbox)
                touched.append(str(INBOX))
        elif act["kind"] == "proposal":
            proposals = read(PROPOSALS, {"version": 1, "items": []})
            eid = "telegram-" + str(uid)
            if not any(str(x.get("event_id") or "") == eid for x in proposals.get("items", [])):
                proposals.setdefault("items", []).append({
                    "event_id": eid, "content": act["text"], "status": "PENDING_RESEARCH",
                    "submitted_at": stamp(), "origin": "telegram_manual"})
                proposals["updated_at"] = stamp()
                save(PROPOSALS, proposals)
                touched.append(str(PROPOSALS))
        state.update(version=1, last_update_id=uid, updated_at=stamp())
        save(STATE, state)
        subprocess.run(["git", "add", *touched], check=True)
        diff = subprocess.run(["git", "diff", "--cached", "--quiet"]).returncode
        if diff == 0:
            return False
        subprocess.run(["git", "commit", "-m", "TTiTTulares native Telegram update " + str(uid)],
                       check=True, stdout=subprocess.DEVNULL)
        push = subprocess.run(["git", "push", "origin", "HEAD:main"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if push.returncode == 0:
            return True
        time.sleep((attempt + 1) * 2)
    raise RuntimeError("TTiTTulares Telegram update failed to persist")


def selftest():
    ledger = {"items": [{"event_id": "abc123xyz", "telegram_message_id": 95,
                         "status": "sent"}]}
    base = {"update_id": 11, "callback_query": {
        "id": "test", "data": "tt:b:abc123xyz",
        "from": {"id": 456},
        "message": {"message_id": 95, "chat": {"id": 456, "type": "private"}}}}
    assert classify(base, "456", ledger)["kind"] == "decision"
    assert classify(base, "999", ledger)["kind"] == "ignore"
    other = json.loads(json.dumps(base))
    other["callback_query"]["message"]["message_id"] = 90
    assert classify(other, "456", ledger)["kind"] == "not_active"
    message = {"update_id": 12, "message": {"chat": {"id": 456, "type": "private"},
                    "from": {"id": 456}, "text": "/run"}}
    assert classify(message, "456", ledger)["kind"] == "run"
    message["message"]["text"] = "/chat ¿Qué tal?"
    assert classify(message, "456", ledger)["kind"] == "requires_conversation_migration"
    print("TTITTULARES_NATIVE_RECEIVER_SELFTEST_OK")


def listen():
    token = os.environ["TELEGRAM_BOT_TOKEN"].strip()
    chat = os.environ["TELEGRAM_CHAT_ID"].strip()
    github = os.environ["GH_TOKEN"].strip()
    if not token or not chat or not github:
        raise SystemExit("Bot token, chat ID or GitHub token unavailable")
    info = telegram_call(token, "getWebhookInfo", {})
    if str(info.get("url") or ""):
        raise SystemExit("SAFE_GUARD: existing Telegram webhook still active; not polling")
    subprocess.run(["git", "config", "user.name", "github-actions[bot]"], check=True)
    subprocess.run(["git", "config", "user.email",
                    "41898282+github-actions[bot]@users.noreply.github.com"], check=True)
    last = int(read(STATE, {"last_update_id": 0}).get("last_update_id") or 0)
    end = time.monotonic() + 24 * 60
    while time.monotonic() < end:
        updates = telegram_call(token, "getUpdates", {
            "offset": last + 1, "limit": 50, "timeout": 20,
            "allowed_updates": ["callback_query", "message"]})
        for update in updates:
            uid = int(update["update_id"])
            if uid <= last:
                continue
            # Load current ledger only for callback decisions; never rely on
            # a stale checkout to authorize publication/deletion.
            if update.get("callback_query"):
                subprocess.run(["git", "fetch", "origin", "main"], check=True,
                               stdout=subprocess.DEVNULL)
                src = subprocess.check_output(
                    ["git", "show", "origin/main:" + str(DELIVERIES)], text=True)
                ledger = json.loads(src)
            else:
                ledger = {"items": []}
            action = classify(update, chat, ledger)
            if action["kind"] == "run":
                cmd, duplicate = request_editorial(github)
                text = ("Ya hay una solicitud reciente. " if duplicate else "Solicitud /run registrada. ") + "ID: " + cmd
                telegram_call(token, "sendMessage", {"chat_id": chat, "text": "TTiTTulares: " + text})
            persisted = commit_event(update, action)
            last = uid
            if action["kind"] == "decision":
                try:
                    telegram_call(token, "answerCallbackQuery", {"callback_query_id": action["callback_id"],
                        "text": "Decisión recibida y registrada."})
                except Exception:
                    telegram_call(token, "sendMessage", {"chat_id": chat,
                        "text": "TTiTTulares: decisión guardada. Mensaje pendiente de actualizar."})
            elif action["kind"] == "proposal":
                telegram_call(token, "sendMessage", {"chat_id": chat,
                    "text": "TTiTTulares: propuesta recibida en la cola."})
            elif action["kind"] == "requires_conversation_migration":
                print("TTI_NATIVE_UNSUPPORTED_CHAT", uid, flush=True)
            if persisted:
                print("TTI_NATIVE_PERSISTED", uid, action["kind"], flush=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        selftest()
    elif len(sys.argv) > 1 and sys.argv[1] == "listen":
        listen()
    else:
        raise SystemExit("Usage: ttittulares_native_receiver.py selftest|listen")
