#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
RECENT = ROOT / "recent.json"
EXPLAINED = ROOT / "explained.json"
STATE = ROOT / "telegram-bot-state.json"
MANUAL = ROOT / "telegram-manual-explained.json"
REQUESTS = ROOT / "requests.json"

TOKEN = os.environ["TTENDENCIAS_BOT_TOKEN"]
API = f"https://api.telegram.org/bot{TOKEN}/"
MADRID = ZoneInfo("Europe/Madrid")


def load(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def persist_git(message="Actualizar estado inmediato TTendencias"):
    paths = [
        "trends/recent.json",
        "trends/checkpoint.json",
        "trends/requests.json",
        "trends/telegram-bot-state.json",
        "trends/telegram-manual-explained.json",
    ]
    subprocess.run(["git","add",*paths], check=False)
    if subprocess.run(["git","diff","--cached","--quiet"], check=False).returncode == 0:
        return
    subprocess.run(["git","config","user.name","ttendencias-bot"], check=False)
    subprocess.run(["git","config","user.email","actions@users.noreply.github.com"], check=False)
    subprocess.run(["git","commit","-m",message], check=False)
    pushed = subprocess.run(["git","push","origin","HEAD:main"], check=False).returncode == 0
    if not pushed:
        subprocess.run(["git","pull","--rebase","--autostash","origin","main"], check=False)
        subprocess.run(["git","push","origin","HEAD:main"], check=False)



def norm(s):
    return " ".join(str(s or "").split()).casefold()


def call(method, payload=None):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + method, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            out = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            out = json.loads(body)
            raise RuntimeError(out.get("description") or out)
        except json.JSONDecodeError:
            raise RuntimeError(body or str(e))
    if not out.get("ok"):
        raise RuntimeError(out.get("description") or out)
    return out.get("result")


def known_explained():
    names = set()
    data = load(EXPLAINED, {})
    for item in data.get("items", []):
        value = item.get("display_name") or item.get("term_normalized")
        if value:
            names.add(norm(value))
    manual = load(MANUAL, {"items": []})
    for item in manual.get("items", []):
        if item.get("name"):
            names.add(norm(item["name"]))
    return names


def current():
    data = load(RECENT, {})
    items = data.get("items") or [
        {"rank": i + 1, "name": x} for i, x in enumerate(data.get("top10", []))
    ]
    return data, items[:10]


def panel_text():
    data, items = current()
    explained = known_explained()
    reqs = load(REQUESTS, {"requests": []}).get("requests", [])
    preparing = {norm(x.get("name")) for x in reqs if x.get("status") in {"preparing", "ready"}}
    updates = {norm(x.get("name")) for x in reqs if x.get("status") == "update"}

    lines = ["📊 TTENDENCIAS · ESPAÑA", ""]
    for item in items:
        rank = int(item["rank"])
        name = str(item["name"])
        k = norm(name)
        if k in updates:
            mark = "🟡"
        elif k in preparing:
            mark = "🔵"
        elif k in explained:
            mark = "🟢"
        else:
            mark = "🔴"
        lines.append(f"{mark} {rank}. {name}")

    captured = data.get("captured_at")
    if captured:
        try:
            dt = datetime.fromisoformat(captured).astimezone(MADRID)
            lines += ["", f'Actualizado {dt.strftime("%H:%M")}']
        except Exception:
            pass
    return "\n".join(lines)


def panel_keyboard():
    _, items = current()
    rows = []
    row = []
    for item in items:
        rank = int(item["rank"])
        row.append({
            "text": str(rank),
            "callback_data": f"trend:{rank}"
        })
        if len(row) == 5:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    rows.append([{"text": "🔄 Actualizar", "callback_data": "panel:refresh"}])
    return {"inline_keyboard": rows}


def sync_panel(force_new=False):
    state = load(STATE, {"chat_id": None, "panel_message_id": None, "last_update_id": 0, "pending": {}})
    chat_id = state.get("chat_id")
    if not chat_id:
        return False
    payload = {
        "chat_id": chat_id,
        "text": panel_text(),
        "reply_markup": panel_keyboard(),
        "disable_web_page_preview": True,
    }
    mid = state.get("panel_message_id")
    if mid and not force_new:
        try:
            call("editMessageText", {**payload, "message_id": mid})
            return True
        except Exception as e:
            if "message is not modified" in str(e).lower():
                return True
            print("No se pudo editar el panel existente:", e, flush=True)
    msg = call("sendMessage", payload)
    state["panel_message_id"] = msg["message_id"]
    save(STATE, state)
    try:
        call("pinChatMessage", {
            "chat_id": chat_id,
            "message_id": msg["message_id"],
            "disable_notification": True,
        })
    except Exception as e:
        print("No se pudo fijar el panel:", e, flush=True)
    return True


def search_url(term):
    return "https://x.com/search?" + urllib.parse.urlencode({
        "q": term, "src": "typed_query", "f": "live"
    })


def select_trend(callback):
    state = load(STATE, {"chat_id": None, "panel_message_id": None, "last_update_id": 0, "pending": {}})
    _, items = current()
    try:
        rank = int(callback["data"].split(":", 1)[1])
        item = next(x for x in items if int(x["rank"]) == rank)
    except Exception:
        call("answerCallbackQuery", {"callback_query_id": callback["id"], "text": "La tabla cambió. Pulsa Actualizar."})
        return
    term = str(item["name"])
    key = hashlib.sha256(term.encode("utf-8")).hexdigest()[:12]
    requests = load(REQUESTS, {"requests": []})
    existing = next(
        (x for x in requests.get("requests", [])
         if norm(x.get("name")) == norm(term) and x.get("status") in {"preparing", "ready"}),
        None
    )
    if not existing:
        requests.setdefault("requests", []).append({
            "id": key,
            "name": term,
            "rank": rank,
            "status": "preparing",
            "requested_at": datetime.now(MADRID).isoformat(timespec="seconds"),
            "revision": 0,
            "reexplain": norm(term) in known_explained(),
        })
        save(REQUESTS, requests)
    sync_panel()
    call("answerCallbackQuery", {
        "callback_query_id": callback["id"],
        "text": "🔵 Enviada a preparación."
    })


def mark_explained(callback):
    key = callback["data"].split(":", 1)[1]
    state = load(STATE, {"pending": {}})
    pending = state.get("pending", {})
    item = pending.get(key)
    if not item:
        call("answerCallbackQuery", {"callback_query_id": callback["id"], "text": "Este bloque ya no está activo."})
        return
    manual = load(MANUAL, {"project": "TTendencias", "items": []})
    if norm(item["name"]) not in {norm(x.get("name")) for x in manual.get("items", [])}:
        manual.setdefault("items", []).append({
            "name": item["name"],
            "explained_at": datetime.now(MADRID).isoformat(timespec="seconds"),
            "source": "telegram_button",
        })
        save(MANUAL, manual)
    try:
        call("deleteMessage", {"chat_id": item["chat_id"], "message_id": item["message_id"]})
    except Exception:
        pass
    pending.pop(key, None)
    state["pending"] = pending
    save(STATE, state)
    requests = load(REQUESTS, {"requests": []})
    for req in requests.get("requests", []):
        if norm(req.get("name")) == norm(item["name"]) and req.get("status") in {"preparing", "ready", "update"}:
            req["status"] = "explained"
            req["explained_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
    save(REQUESTS, requests)
    sync_panel()
    call("answerCallbackQuery", {"callback_query_id": callback["id"], "text": "Marcada como explicada"})


def close_block(callback):
    key = callback["data"].split(":", 1)[1]
    state = load(STATE, {"pending": {}})
    item = state.get("pending", {}).pop(key, None)
    if item:
        save(STATE, state)
        try:
            call("deleteMessage", {"chat_id": item["chat_id"], "message_id": item["message_id"]})
        except Exception:
            pass
    call("answerCallbackQuery", {"callback_query_id": callback["id"]})


def handle(update):
    state = load(STATE, {"chat_id": None, "panel_message_id": None, "last_update_id": 0, "pending": {}})
    message = update.get("message")
    if message:
        text = (message.get("text") or "").strip().lower()
        if text in {"/start", "/panel", "/tt"}:
            state["chat_id"] = message["chat"]["id"]
            save(STATE, state)
            sync_panel()
            persist_git("Enlazar chat del bot TTendencias")
            return
    cb = update.get("callback_query")
    if not cb:
        return
    data = cb.get("data", "")
    if data.startswith("trend:"):
        select_trend(cb)
    elif data.startswith("explained:"):
        mark_explained(cb)
    elif data.startswith("close:"):
        close_block(cb)
    elif data == "panel:refresh":
        subprocess.run(["python3", str(ROOT / "update_trends.py")], check=False)
        sync_panel()
        persist_git("Actualizar manualmente Top 10 TTendencias")
        call("answerCallbackQuery", {"callback_query_id": cb["id"], "text": "Top 10 actualizado"})


def poll(seconds=3300):
    started = time.time()
    state = load(STATE, {"chat_id": None, "panel_message_id": None, "last_update_id": 0, "pending": {}})
    offset = int(state.get("last_update_id") or 0) + 1
    last_sync = 0
    while time.time() - started < seconds:
        if time.time() - last_sync > 900:
            try:
                subprocess.run(["python3", str(ROOT / "update_trends.py")], check=False)
                sync_panel()
                persist_git("Refrescar panel TTendencias")
            except Exception as e:
                print("sync error:", e, flush=True)
            last_sync = time.time()
        try:
            updates = call("getUpdates", {"offset": offset, "timeout": 25, "allowed_updates": ["message", "callback_query"]}) or []
            for upd in updates:
                offset = max(offset, int(upd["update_id"]) + 1)
                handle(upd)
                state = load(STATE, state)
                state["last_update_id"] = int(upd["update_id"])
                save(STATE, state)
                persist_git()
        except Exception as e:
            print("poll error:", e, flush=True)
            time.sleep(3)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "sync"
    if mode == "listen":
        poll(int(os.environ.get("TTENDENCIAS_LISTEN_SECONDS", "3300")))
    elif mode == "sync":
        sync_panel()
    elif mode == "force":
        sync_panel(force_new=True)
        persist_git("Recrear panel TTendencias")
    else:
        raise SystemExit("Uso: telegram_bot.py [sync|listen|force]")
