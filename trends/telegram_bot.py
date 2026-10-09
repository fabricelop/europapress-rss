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
LISTENER_STATE = ROOT / "telegram-listener-state.json"
MANUAL = ROOT / "telegram-manual-explained.json"
REQUESTS = ROOT / "requests.json"
PREPARED = ROOT / "prepared.json"
IMAGE_DELIVERIES = ROOT / "telegram-image-deliveries.json"
PACKAGE_STATE = ROOT / "telegram-package-listener-state.json"
COPY_STATE = ROOT / "explained-copy-state.json"

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


def load_remote_json(repo_path, default):
    """Lee la versión más reciente del fichero desde origin/main sin hacer checkout/pull."""
    try:
        subprocess.run(
            ["git", "fetch", "origin", "main"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        out = subprocess.run(
            ["git", "show", f"origin/main:{repo_path}"],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(out.stdout)
    except Exception as e:
        print(f"No se pudo leer estado remoto {repo_path}: {e}", flush=True)
        return default

def persist_git(message="Actualizar estado inmediato TTendencias", include_trends=False):
    # Persistencia con fusión semántica. Nunca hacemos rebase ciego de JSON:
    # explained gana a ready/preparing y los estados internos del listener se
    # fusionan sin pisar pending del emisor.
    paths = [
        "trends/requests.json",
        "trends/telegram-bot-state.json",
        "trends/telegram-listener-state.json",
        "trends/telegram-manual-explained.json",
        "trends/prepared.json",
    ]
    if include_trends:
        paths = ["trends/recent.json", "trends/checkpoint.json", *paths]

    stamp = str(time.time_ns())
    tmp = Path("/tmp") / f"ttendencias-{stamp}"
    tmp.mkdir(parents=True, exist_ok=True)

    local = {}
    for rel in paths:
        src = Path(rel)
        if src.exists():
            dst = tmp / src.name
            dst.write_bytes(src.read_bytes())
            local[rel] = dst

    subprocess.run(["git", "config", "user.name", "ttendencias-bot"], check=False)
    subprocess.run(["git", "config", "user.email", "actions@users.noreply.github.com"], check=False)

    for attempt in range(3):
        subprocess.run(["git", "fetch", "origin", "main"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if subprocess.run(["git", "reset", "--hard", "origin/main"], check=False).returncode != 0:
            continue

        if include_trends:
            for rel in ("trends/recent.json", "trends/checkpoint.json"):
                if rel in local:
                    Path(rel).write_bytes(local[rel].read_bytes())

        merge_cmd = ["python3", str(ROOT / "merge_runtime_state.py")]
        if "trends/requests.json" in local:
            merge_cmd += ["--local-requests", str(local["trends/requests.json"])]
        if "trends/telegram-bot-state.json" in local:
            merge_cmd += ["--local-state", str(local["trends/telegram-bot-state.json"])]
        if "trends/telegram-listener-state.json" in local:
            merge_cmd += ["--local-listener", str(local["trends/telegram-listener-state.json"])]
        if "trends/telegram-manual-explained.json" in local:
            merge_cmd += ["--local-manual", str(local["trends/telegram-manual-explained.json"])]
        if "trends/prepared.json" in local:
            merge_cmd += ["--local-prepared", str(local["trends/prepared.json"])]
        subprocess.run(merge_cmd, check=False)

        subprocess.run(["git", "add", *paths], check=False)
        if subprocess.run(["git", "diff", "--cached", "--quiet"], check=False).returncode == 0:
            return True
        if subprocess.run(["git", "commit", "-m", message], check=False).returncode != 0:
            continue
        if subprocess.run(["git", "push", "origin", "HEAD:main"], check=False).returncode == 0:
            return True

    print("No se pudo persistir estado TTendencias tras 3 intentos", flush=True)
    return False


def merge_instagram_last_action(remote_state, local_state):
    """Preserve the latest Instagram button outcome across GitHub state merges."""
    remote = remote_state.get("instagram_last_action")
    incoming = local_state.get("instagram_last_action")
    if not isinstance(incoming, dict) or not incoming.get("event_id"):
        return
    def timestamp(row):
        try:
            return datetime.fromisoformat(
                str(row.get("updated_at") or "").replace("Z", "+00:00")
            ).timestamp()
        except (ValueError, TypeError, OverflowError):
            return 0
    if not isinstance(remote, dict) or timestamp(incoming) >= timestamp(remote):
        remote_state["instagram_last_action"] = dict(incoming)


def persist_package_state(message="Actualizar paquetes Telegram TTendencias"):
    """Fusiona solo decisiones de paquetes y offset del listener sobre main fresco."""
    stamp = str(time.time_ns())
    tmp = Path("/tmp") / f"ttendencias-package-{stamp}"
    tmp.mkdir(parents=True, exist_ok=True)

    snapshots = {}
    for rel, path in (
        ("trends/telegram-image-deliveries.json", IMAGE_DELIVERIES),
        ("trends/telegram-manual-explained.json", MANUAL),
        ("trends/telegram-package-listener-state.json", PACKAGE_STATE),
        ("trends/explained-copy-state.json", COPY_STATE),
    ):
        if path.exists():
            dst = tmp / path.name
            dst.write_bytes(path.read_bytes())
            snapshots[rel] = dst

    subprocess.run(["git", "config", "user.name", "ttendencias-package-bot"], check=False)
    subprocess.run(["git", "config", "user.email", "actions@users.noreply.github.com"], check=False)

    for attempt in range(5):
        subprocess.run(["git", "fetch", "origin", "main"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if subprocess.run(["git", "reset", "--hard", "origin/main"], check=False).returncode != 0:
            time.sleep((attempt + 1) * 2)
            continue

        remote_del = load(IMAGE_DELIVERIES, {"version": 1, "items": []})
        local_del = load(snapshots.get("trends/telegram-image-deliveries.json", Path("/nonexistent")), {"items": []})
        by_key = {
            str(x.get("delivery_key") or ""): x
            for x in remote_del.get("items", [])
            if x.get("delivery_key")
        }
        for incoming in local_del.get("items", []):
            status = str(incoming.get("status") or "").lower()
            if status not in {"published", "dismissed"}:
                continue
            key = str(incoming.get("delivery_key") or "")
            if not key:
                continue
            cur = by_key.get(key)
            if cur is None:
                cur = dict(incoming)
                remote_del.setdefault("items", []).append(cur)
                by_key[key] = cur
            else:
                for k in (
                    "status", "published_at", "dismissed_at", "decision_source",
                    "telegram_message_id", "archive_telegram_message_id",
                ):
                    if k in incoming:
                        cur[k] = incoming[k]
        remote_del["items"] = remote_del.get("items", [])[-500:]
        remote_del["count"] = len(remote_del["items"])
        remote_del["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
        save(IMAGE_DELIVERIES, remote_del)

        remote_manual = load(MANUAL, {"items": []})
        local_manual = load(snapshots.get("trends/telegram-manual-explained.json", Path("/nonexistent")), {"items": []})
        local_actions = {}
        for x in local_manual.get("items", []):
            if str(x.get("telegram_package_status") or "").lower() in {"published", "dismissed"}:
                local_actions[(str(x.get("id") or ""), int(x.get("revision") or 0))] = x
        for row in remote_manual.get("items", []):
            src = local_actions.get((str(row.get("id") or ""), int(row.get("revision") or 0)))
            if not src:
                continue
            for k in (
                "telegram_package_status", "telegram_package_updated_at",
                "telegram_published_at", "telegram_dismissed_at",
                "telegram_decision_source",
            ):
                if k in src:
                    row[k] = src[k]
        remote_manual["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
        save(MANUAL, remote_manual)

        remote_state = load(PACKAGE_STATE, {"version": 1, "last_update_id": 0})
        local_state = load(snapshots.get("trends/telegram-package-listener-state.json", Path("/nonexistent")), {"last_update_id": 0})
        remote_state["version"] = 1
        remote_state["last_update_id"] = max(
            int(remote_state.get("last_update_id") or 0),
            int(local_state.get("last_update_id") or 0),
        )
        remote_state["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
        merge_instagram_last_action(remote_state, local_state)
        save(PACKAGE_STATE, remote_state)

        remote_copy = load(COPY_STATE, {"version": 1, "items": []})
        local_copy = load(snapshots.get("trends/explained-copy-state.json", Path("/nonexistent")), {"items": []})
        copy_keys = {
            (str(x.get("item_id") or ""), int(x.get("revision") or 0))
            for x in remote_copy.get("items", [])
        }
        for incoming in local_copy.get("items", []):
            key = (str(incoming.get("item_id") or ""), int(incoming.get("revision") or 0))
            if not key[0] or key in copy_keys:
                continue
            remote_copy.setdefault("items", []).append(incoming)
            copy_keys.add(key)
        remote_copy["count"] = len(remote_copy.get("items", []))
        remote_copy["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
        save(COPY_STATE, remote_copy)

        subprocess.run([
            "git", "add",
            "trends/telegram-image-deliveries.json",
            "trends/telegram-manual-explained.json",
            "trends/telegram-package-listener-state.json",
            "trends/explained-copy-state.json",
        ], check=False)
        if subprocess.run(["git", "diff", "--cached", "--quiet"], check=False).returncode == 0:
            return True
        if subprocess.run(["git", "commit", "-m", message], check=False).returncode != 0:
            time.sleep((attempt + 1) * 2)
            continue
        if subprocess.run(["git", "push", "origin", "HEAD:main"], check=False).returncode == 0:
            return True
        time.sleep((attempt + 1) * 2)

    print("No se pudo persistir paquete TTendencias tras 5 intentos", flush=True)
    return False


def handle_package_callback(callback):
    data = str(callback.get("data") or "")
    parts = data.split(":")
    if len(parts) != 4 or parts[0] != "tx" or parts[1] not in {"p", "d"}:
        return False

    action, trend_id = parts[1], parts[2]
    try:
        revision = int(parts[3])
    except Exception:
        revision = 0

    bot_state = load_remote_json("trends/telegram-bot-state.json", load(STATE, {}))
    allowed_chat = int(bot_state.get("chat_id") or 0)
    message = callback.get("message") or {}
    chat_id = int((message.get("chat") or {}).get("id") or 0)
    if not allowed_chat or chat_id != allowed_chat:
        try:
            call("answerCallbackQuery", {
                "callback_query_id": callback["id"],
                "text": "Chat no autorizado.",
                "show_alert": True,
            })
        except Exception:
            pass
        return True

    try:
        call("answerCallbackQuery", {
            "callback_query_id": callback["id"],
            "text": "Guardando publicación…" if action == "p" else "Guardando descarte…",
        })
    except Exception:
        pass

    deliveries = load_remote_json(
        "trends/telegram-image-deliveries.json",
        load(IMAGE_DELIVERIES, {"version": 1, "items": []}),
    )
    manual = load_remote_json(
        "trends/telegram-manual-explained.json",
        load(MANUAL, {"items": []}),
    )
    copy_state = load_remote_json(
        "trends/explained-copy-state.json",
        load(COPY_STATE, {"version": 1, "items": []}),
    )

    status = "published" if action == "p" else "dismissed"
    now = datetime.now(MADRID).isoformat(timespec="seconds")
    mids = []
    matched = False

    for row in deliveries.get("items", []):
        if str(row.get("event_id") or "") != trend_id or int(row.get("revision") or 0) != revision:
            continue
        current = str(row.get("status") or "").lower()
        if current not in {"sent", status}:
            continue
        matched = True
        row["status"] = status
        row["decision_source"] = "telegram_package"
        row["published_at" if status == "published" else "dismissed_at"] = now
        for k in ("telegram_message_id", "archive_telegram_message_id"):
            mid = int(row.get(k) or 0)
            if mid and mid not in mids:
                mids.append(mid)

    current_mid = int(message.get("message_id") or 0)
    if current_mid and current_mid not in mids:
        mids.append(current_mid)

    for row in manual.get("items", []):
        if str(row.get("id") or "") == trend_id and int(row.get("revision") or 0) == revision:
            row["telegram_package_status"] = status
            row["telegram_package_updated_at"] = now
            row["telegram_decision_source"] = "telegram_package"
            row["telegram_published_at" if status == "published" else "telegram_dismissed_at"] = now
            matched = True

    if not matched:
        try:
            call("sendMessage", {
                "chat_id": chat_id,
                "text": "⚠️ No encuentro el paquete vigente de TTendencias.",
            })
        except Exception:
            pass
        return True

    existing_copy = {
        (str(x.get("item_id") or ""), int(x.get("revision") or 0))
        for x in copy_state.get("items", [])
    }
    if (trend_id, revision) not in existing_copy:
        source_row = next(
            (x for x in manual.get("items", [])
             if str(x.get("id") or "") == trend_id and int(x.get("revision") or 0) == revision),
            {},
        )
        copy_state.setdefault("items", []).append({
            "item_id": trend_id,
            "revision": revision,
            "copied_at": now,
            "trend_names": source_row.get("trend_names") or ([source_row.get("name")] if source_row.get("name") else []),
            "explanation": str(source_row.get("explanation") or ""),
            "copy_key": str(source_row.get("copy_key") or f"{trend_id}:r{revision}"),
            "closed_from": "telegram_package",
            "telegram_package_status": status,
        })
        copy_state["count"] = len(copy_state["items"])
        copy_state["updated_at"] = now

    save(IMAGE_DELIVERIES, deliveries)
    save(MANUAL, manual)
    save(COPY_STATE, copy_state)

    if not persist_package_state("Cerrar paquete TTendencias desde Telegram"):
        try:
            call("sendMessage", {
                "chat_id": chat_id,
                "text": "⚠️ No se pudo guardar el estado de TTendencias; el mensaje se conserva.",
            })
        except Exception:
            pass
        return True

    deleted = 0
    for mid in mids:
        try:
            call("deleteMessage", {"chat_id": chat_id, "message_id": mid})
            deleted += 1
        except Exception as e:
            if "message to delete not found" in str(e).lower():
                deleted += 1
            else:
                print(f"No se pudo borrar paquete TTendencias {mid}: {e}", flush=True)

    print("TTENDENCIAS_PACKAGE_CLOSED", trend_id, revision, status, "deleted", deleted, flush=True)
    return True


def norm(s):
    return " ".join(str(s or "").split()).casefold()

def noise_name(s):
    v = norm(s)
    return (
        v.startswith("explore why ")
        or (" is trending " in (" " + v + " ") and "latest viral tweets" in v)
        or "real-time buzz from twitter" in v
    )


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
    # Leer siempre la versión remota más reciente para que un listener
    # de larga duración no conserve verdes obsoletos.
    names = set()
    manual = load_remote_json(
        "trends/telegram-manual-explained.json",
        load(MANUAL, {"items": []})
    )
    for item in manual.get("items", []):
        if item.get("name") and not noise_name(item.get("name")):
            names.add(norm(item["name"]))
    return names


def current():
    data = load(RECENT, {})
    items = data.get("items") or [
        {"rank": i + 1, "name": x} for i, x in enumerate(data.get("top10", []))
    ]
    return data, items[:10]


def panel_text():
    data, _ = current()
    lines = ["📊 TTENDENCIAS · ESPAÑA"]
    captured = data.get("captured_at")
    if captured:
        try:
            dt = datetime.fromisoformat(captured).astimezone(MADRID)
            lines.append(f'Actualizado {dt.strftime("%H:%M")}')
        except Exception:
            pass
    return "\n".join(lines)


def trend_statuses():
    _, items = current()
    explained = known_explained()

    # Fusionar cola remota con selecciones locales aún no persistidas.
    local_data = load(REQUESTS, {"requests": []})
    remote_data = load_remote_json("trends/requests.json", {"requests": []})
    by_id = {
        str(x.get("id")): x
        for x in remote_data.get("requests", [])
        if x.get("id")
    }
    for local_item in local_data.get("requests", []):
        lid = str(local_item.get("id") or "")
        if not lid:
            continue
        remote_item = by_id.get(lid)
        if (
            remote_item is None
            or local_item.get("status") in {"preparing", "ready", "update"}
        ):
            by_id[lid] = local_item

    reqs = list(by_id.values())
    preparing = {norm(x.get("name")) for x in reqs if x.get("status") in {"preparing", "ready"}}
    updates = {norm(x.get("name")) for x in reqs if x.get("status") == "update"}

    out = []
    for item in items:
        rank = int(item["rank"])
        name = str(item["name"])
        k = norm(name)
        if k in updates:
            mark = "🟡"
            status = "yellow"
        elif k in preparing:
            mark = "🔵"
            status = "blue"
        elif k in explained:
            mark = "🟢"
            status = "green"
        else:
            mark = "🔴"
            status = "red"
        out.append({
            "rank": rank,
            "name": name,
            "key": k,
            "mark": mark,
            "status": status,
        })
    return out


def panel_keyboard():
    state = load(LISTENER_STATE, {})
    selected = {int(x) for x in state.get("batch_selection", []) if str(x).isdigit()}
    rows = []
    for item in trend_statuses():
        chosen = item["rank"] in selected
        mark = "☑️" if chosen else item["mark"]
        label = f'{mark}  {item["rank"]:>2}   {item["name"]}'
        rows.append([{
            "text": label[:64],
            "callback_data": f'toggle:{item["rank"]}',
        }])
    if selected:
        rows.append([
            {"text": f"📝 Explicar ({len(selected)})", "callback_data": "batch:text"},
            {"text": f"🖼️ Con imagen ({len(selected)})", "callback_data": "batch:image"},
            {"text": "✖️", "callback_data": "batch:cancel"},
        ])
    rows.append([{"text": "🔄 Actualizar ahora", "callback_data": "panel:refresh"}])
    return {"inline_keyboard": rows}

def send_new_status_alerts(state):
    chat_id = state.get("chat_id")
    if not chat_id:
        return

    listener_state = load(LISTENER_STATE, {})
    current_items = trend_statuses()
    previous = listener_state.get("alert_status_snapshot")

    # Primera ejecución tras activar la función: fijamos una línea base para
    # no enviar de golpe alertas por tendencias que ya estaban en la tabla.
    if previous is None:
        listener_state["alert_status_snapshot"] = {
            item["key"]: item["status"] for item in current_items
        }
        save(LISTENER_STATE, listener_state)
        return

    for item in current_items:
        prev_status = previous.get(item["key"])
        status = item["status"]

        should_alert = (
            (status == "red" and prev_status is None)
            or (status == "yellow" and prev_status != "yellow")
        )
        if not should_alert:
            continue

        text = f'T{item["rank"]} · {item["name"]}'
        try:
            call("sendMessage", {
                "chat_id": chat_id,
                "text": text,
                "reply_markup": {
                    "inline_keyboard": [[{
                        "text": "🗑️ Borrar",
                        "callback_data": "alert:delete",
                    }]]
                },
                "disable_web_page_preview": True,
            })
        except Exception as e:
            print("No se pudo enviar alerta TTendencias:", e, flush=True)

    listener_state["alert_status_snapshot"] = {
        item["key"]: item["status"] for item in current_items
    }
    save(LISTENER_STATE, listener_state)


def unpin_panels(chat_id):
    try:
        call("unpinAllChatMessages", {"chat_id": chat_id})
    except Exception as e:
        print("No se pudieron desanclar mensajes:", e, flush=True)


def delete_panel(chat_id, message_id):
    if not message_id:
        return
    try:
        call("deleteMessage", {"chat_id": chat_id, "message_id": int(message_id)})
    except Exception as e:
        print(f"No se pudo borrar panel {message_id}:", e, flush=True)


def cleanup_old_panels(state, keep=None):
    chat_id = state.get("chat_id")
    if not chat_id:
        return
    ids = set(state.get("panel_message_ids") or [])
    current = state.get("panel_message_id")
    if current:
        ids.add(current)
    # Paneles creados durante la puesta en marcha antes de guardar historial.
    ids.update([4, 6, 8, 62])
    for mid in sorted(ids):
        if keep is not None and int(mid) == int(keep):
            continue
        delete_panel(chat_id, mid)
    state["panel_message_ids"] = [keep] if keep else []


def sync_panel(force_new=False):
    state = load(STATE, {
        "chat_id": None,
        "panel_message_id": None,
        "panel_message_ids": [],
        "last_update_id": 0,
        "pending": {}
    })
    chat_id = state.get("chat_id")
    if not chat_id:
        return False

    unpin_panels(chat_id)

    payload = {
        "chat_id": chat_id,
        "text": panel_text(),
        "reply_markup": panel_keyboard(),
        "disable_web_page_preview": True,
    }

    mid = state.get("panel_message_id")
    if mid and not force_new:
        try:
            call("editMessageText", {**payload, "message_id": int(mid)})
            state["panel_message_ids"] = [int(mid)]
            send_new_status_alerts(state)
            save(STATE, state)
            return True
        except Exception as e:
            if "message is not modified" in str(e).lower():
                state["panel_message_ids"] = [int(mid)]
                send_new_status_alerts(state)
                save(STATE, state)
                return True
            print("No se pudo editar el panel existente:", e, flush=True)

    # Si la referencia guardada ya no se puede editar, intentar borrar ese
    # mensaje explícitamente antes de crear el sustituto. Así no dejamos
    # tablas antiguas visibles cuando Telegram devuelve un error de edición.
    if mid:
        delete_panel(chat_id, mid)
    cleanup_old_panels(state)
    msg = call("sendMessage", payload)
    new_mid = int(msg["message_id"])
    state["panel_message_id"] = new_mid
    state["panel_message_ids"] = [new_mid]
    send_new_status_alerts(state)
    save(STATE, state)

    return True


def search_url(term):
    return "https://x.com/search?" + urllib.parse.urlencode({
        "q": term, "src": "typed_query", "f": "live"
    })


def refresh_trends_now():
    before = load(RECENT, {}).get("captured_at")
    result = subprocess.run(
        ["python3", str(ROOT / "update_trends.py")],
        check=False,
    )
    after = load(RECENT, {}).get("captured_at")
    ok = result.returncode == 0 and after and after != before
    return ok, before, after


def refresh_panel_message(callback):
    state = load(STATE, {})
    chat_id = state.get("chat_id") or callback["message"]["chat"]["id"]
    mid = state.get("panel_message_id") or callback["message"]["message_id"]
    try:
        call("editMessageText", {
            "chat_id": chat_id,
            "message_id": int(mid),
            "text": panel_text(),
            "reply_markup": panel_keyboard(),
            "disable_web_page_preview": True,
        })
    except Exception as exc:
        if "message is not modified" not in str(exc).lower():
            print("No se pudo refrescar el panel:", exc, flush=True)


def toggle_trend(callback):
    _, items = current()
    try:
        rank = int(callback["data"].split(":", 1)[1])
        next(x for x in items if int(x["rank"]) == rank)
    except Exception:
        call("answerCallbackQuery", {
            "callback_query_id": callback["id"],
            "text": "La tabla cambió; vuelve a pulsar la tendencia."
        })
        return

    state = load(LISTENER_STATE, {})
    selected = {int(x) for x in state.get("batch_selection", []) if str(x).isdigit()}
    if rank in selected:
        selected.remove(rank)
    else:
        selected.add(rank)
    state["batch_selection"] = sorted(selected)
    save(LISTENER_STATE, state)
    try:
        call("answerCallbackQuery", {"callback_query_id": callback["id"]})
    except Exception:
        pass
    refresh_panel_message(callback)


def submit_batch(callback, with_image=False):
    _, items = current()
    state = load(LISTENER_STATE, {})
    selected = sorted({int(x) for x in state.get("batch_selection", []) if str(x).isdigit()})
    chosen = [x for x in items if int(x["rank"]) in selected]
    if not chosen:
        call("answerCallbackQuery", {
            "callback_query_id": callback["id"],
            "text": "No hay tendencias seleccionadas."
        })
        return

    local_requests = load(REQUESTS, {"requests": []})
    requests = load_remote_json("trends/requests.json", {"requests": []})
    by_id = {str(x.get("id")): x for x in requests.get("requests", []) if x.get("id")}
    for x in local_requests.get("requests", []):
        xid = str(x.get("id") or "")
        if xid and (xid not in by_id or x.get("status") in {"preparing", "ready", "update"}):
            by_id[xid] = x

    now = datetime.now(MADRID).isoformat(timespec="seconds")
    names = [str(x["name"]) for x in chosen]
    batch_basis = " | ".join(names) + " | " + now
    batch_id = hashlib.sha256(batch_basis.encode("utf-8")).hexdigest()[:12]
    explained = known_explained()

    for item in chosen:
        term = str(item["name"])
        key = hashlib.sha256(term.encode("utf-8")).hexdigest()[:12]
        existing = next((x for x in by_id.values()
                         if norm(x.get("name")) == norm(term)
                         and x.get("status") in {"preparing", "ready", "update"}), None)
        if existing:
            existing["with_image"] = bool(with_image) or bool(existing.get("with_image"))
            existing["alternatives_target"] = 3
            existing["batch_id"] = batch_id
            existing["requested_together"] = names
            if existing.get("status") == "ready":
                existing["status"] = "update"
                existing["requested_at"] = now
                existing["revision"] = int(existing.get("revision") or 0) + 1
                existing["reexplain"] = True
                existing.pop("telegram_message_id", None)
        else:
            reexplain = norm(term) in explained
            previous = by_id.get(key) or {}
            by_id[key] = {
                "id": key,
                "name": term,
                "rank": int(item["rank"]),
                "status": "update" if reexplain else "preparing",
                "requested_at": now,
                "revision": int(previous.get("revision") or 0) + (1 if reexplain else 0),
                "reexplain": reexplain,
                "with_image": bool(with_image),
                "alternatives_target": 3,
                "batch_id": batch_id,
                "requested_together": names,
            }

    requests["requests"] = list(by_id.values())
    save(REQUESTS, requests)
    state["batch_selection"] = []
    save(LISTENER_STATE, state)
    # Persistir inmediatamente la cola: si el listener termina o un workflow
    # hace checkout después, no se pierde ni el lote ni with_image.
    persist_git("Encolar lote TTendencias" + (" con imagen" if with_image else ""))
    try:
        call("answerCallbackQuery", {
            "callback_query_id": callback["id"],
            "text": ("🖼️ " if with_image else "📝 ") + f"{len(chosen)} tendencia(s) enviadas juntas"
        })
    except Exception:
        pass
    refresh_panel_message(callback)


def cancel_batch(callback):
    state = load(LISTENER_STATE, {})
    state["batch_selection"] = []
    save(LISTENER_STATE, state)
    try:
        call("answerCallbackQuery", {"callback_query_id": callback["id"], "text": "Selección cancelada"})
    except Exception:
        pass
    refresh_panel_message(callback)


def mark_explained(callback):
    key = callback["data"].split(":", 1)[1]
    callback_message = callback.get("message") or {}
    callback_mid = callback_message.get("message_id")
    callback_chat_id = (callback_message.get("chat") or {}).get("id")

    state = load_remote_json(
        "trends/telegram-bot-state.json",
        load(STATE, {"pending": {}})
    )
    pending = state.get("pending", {})
    requests = load_remote_json(
        "trends/requests.json",
        load(REQUESTS, {"requests": []})
    )

    related_trends = []
    if callback_mid:
        related_trends = [
            str(req.get("name")).strip()
            for req in requests.get("requests", [])
            if int(req.get("telegram_message_id") or 0) == int(callback_mid)
            and str(req.get("name") or "").strip()
        ]

    if not related_trends:
        item = pending.get(key)
        if item:
            related_trends = [
                str(x).strip() for x in item.get("related_trends", [])
                if str(x).strip()
            ] or [str(item.get("name") or "").strip()]

    # Si el listener se reinició, pending puede haberse perdido aunque el
    # botón editorial siga visible. Recuperar por id de solicitud.
    if not related_trends:
        req = next(
            (x for x in requests.get("requests", [])
             if str(x.get("id") or "") == str(key)),
            None,
        )
        if req:
            related_trends = [
                str(x).strip() for x in req.get("requested_together", [])
                if str(x).strip()
            ] or [str(req.get("name") or "").strip()]

    related_trends = [x for x in related_trends if x]
    related_norm = {norm(x) for x in related_trends}
    now = datetime.now(MADRID).isoformat(timespec="seconds")

    # EXPLICADA: cerrar el bloque editorial y dejar todas las tendencias
    # representadas en verde. Si después se vuelve a pulsar una verde,
    # select_trend la pondrá azul para reexplicarla.
    manual = load_remote_json(
        "trends/telegram-manual-explained.json",
        load(MANUAL, {"project": "TTendencias", "items": []})
    )
    manual.setdefault("items", [])
    by_name = {norm(x.get("name")): i for i, x in enumerate(manual.get("items", [])) if x.get("name")}
    for trend_name in related_trends:
        key = norm(trend_name)
        if key in by_name:
            i = by_name[key]
            manual["items"][i] = {
                **manual["items"][i],
                "name": trend_name,
                "explained_at": now,
                "source": "telegram_button",
            }
        else:
            manual["items"].append({
                "name": trend_name,
                "explained_at": now,
                "source": "telegram_button",
            })
            by_name[key] = len(manual["items"]) - 1
    save(MANUAL, manual)

    for req in requests.get("requests", []):
        same_message = callback_mid and int(req.get("telegram_message_id") or 0) == int(callback_mid)
        same_name = norm(req.get("name")) in related_norm
        if same_message or same_name:
            req["status"] = "explained"
            req["explained_at"] = now
            req.pop("telegram_message_id", None)
    save(REQUESTS, requests)

    prepared = load_remote_json(
        "trends/prepared.json",
        load(PREPARED, {"project": "TTendencias", "items": []})
    )
    prepared["items"] = [
        item for item in prepared.get("items", [])
        if not any(
            norm(x) in related_norm
            for x in (item.get("related_trends") or [item.get("trend_name")])
            if x
        )
    ]
    prepared["updated_at"] = now
    save(PREPARED, prepared)

    # Borrar exactamente el mensaje cuyo botón se ha pulsado.
    try:
        if callback_chat_id and callback_mid:
            call("deleteMessage", {
                "chat_id": callback_chat_id,
                "message_id": int(callback_mid),
            })
    except Exception as e:
        print("No se pudo borrar el bloque explicado:", e, flush=True)

    # Limpiar cualquier índice pendiente asociado al mismo mensaje o key.
    for pending_key, pending_item in list(pending.items()):
        same_mid = callback_mid and int(pending_item.get("message_id") or 0) == int(callback_mid)
        if same_mid or pending_key == key:
            pending.pop(pending_key, None)
    state["pending"] = pending
    save(STATE, state)

    try:
        call("answerCallbackQuery", {
            "callback_query_id": callback["id"],
            "text": "Marcada como explicada"
        })
    except Exception:
        pass

    persist_git("Cerrar bloque TTendencias y devolver tendencia a rojo")
    sync_panel()


def close_block(callback):
    key = callback["data"].split(":", 1)[1]
    callback_message = callback.get("message") or {}
    callback_mid = callback_message.get("message_id")
    callback_chat_id = (callback_message.get("chat") or {}).get("id")

    # CERRAR solo elimina el mensaje editorial. No cambia el estado de la tendencia.
    try:
        if callback_chat_id and callback_mid:
            call("deleteMessage", {
                "chat_id": callback_chat_id,
                "message_id": int(callback_mid),
            })
    except Exception as e:
        print("No se pudo cerrar el bloque TTendencias:", e, flush=True)

    state = load_remote_json(
        "trends/telegram-bot-state.json",
        load(STATE, {"pending": {}})
    )
    pending = state.get("pending", {})
    for pending_key, pending_item in list(pending.items()):
        same_mid = callback_mid and int(pending_item.get("message_id") or 0) == int(callback_mid)
        if same_mid or pending_key == key:
            pending.pop(pending_key, None)
    state["pending"] = pending
    save(STATE, state)

    try:
        call("answerCallbackQuery", {"callback_query_id": callback["id"]})
    except Exception:
        pass

    persist_git("Cerrar mensaje editorial TTendencias")



def decode_instagram_publisher_response(response, http_status=200):
    """Decode only a small JSON response. Cloudflare may return HTML on 5xx."""
    try:
        payload = json.loads(response.read(32768).decode("utf-8"))
    except (ValueError, UnicodeError):
        return {"state": "transport_error", "error": "NON_JSON_RESPONSE",
                "_http_status": int(http_status)}
    if not isinstance(payload, dict):
        return {"state": "transport_error", "error": "INVALID_JSON_RESPONSE",
                "_http_status": int(http_status)}
    payload["_http_status"] = int(http_status)
    return payload


def handle_instagram_package_callback(callback):
    """Handle explicit Instagram selection; never update X or delete Telegram."""
    data=str(callback.get("data") or "")
    parts=data.split(":")
    if len(parts)!=4 or parts[:2]!=["tx","i"]:
        return False
    trend_id=parts[2]
    try:
        rev=int(parts[3])
    except (ValueError,TypeError):
        return True
    state=load_remote_json("trends/telegram-bot-state.json",load(STATE,{}))
    allowed_chat=int(state.get("chat_id") or 0)
    message=callback.get("message") or {}
    chat_id=int((message.get("chat") or {}).get("id") or 0)
    message_id=int(message.get("message_id") or 0)
    if not allowed_chat or allowed_chat!=chat_id or message_id<=0:
        call("answerCallbackQuery",{"callback_query_id":callback["id"],"text":"Chat no autorizado.","show_alert":True})
        return "unauthorized_chat"

    # ACK before doing slow Meta calls to avoid an expired Telegram callback.
    try:
        call("answerCallbackQuery",{"callback_query_id":callback["id"],"text":"Recibido. Verificando Instagram…"})
    except Exception as exc:
        # A long-running GitHub listener can receive expired callback IDs.
        # Never launch a Meta write for an expired callback: notify in Telegram
        # so the user can select the item again deliberately.
        print("TT_INSTAGRAM_CALLBACK_EXPIRED_OR_FAILED",type(exc).__name__,flush=True)
        try:
            call("sendMessage",{"chat_id":chat_id,
                "text":"La solicitud de Instagram ha caducado antes de procesarse. No se ha lanzado una nueva publicación; vuelve a pulsar el botón si quieres intentarlo.",
                "reply_to_message_id":message_id})
        except Exception as notify_exc:
            print("TT_INSTAGRAM_CALLBACK_NOTIFY_FAILED",type(notify_exc).__name__,flush=True)
        return "expired_callback"
    endpoint=str(os.environ.get("INSTAGRAM_PUBLISHER_URL") or "").rstrip("/")
    secret=str(os.environ.get("INSTAGRAM_INTERNAL_SECRET") or "")
    if (not endpoint.startswith("https://") or len(secret)<32):
        call("sendMessage",{"chat_id":chat_id,"text":"Instagram aún no está activado; el mensaje se conserva.","reply_to_message_id":message_id})
        return "not_configured"
    doc=load_remote_json("trends/telegram-image-deliveries.json",load(IMAGE_DELIVERIES,{"items":[]}))
    matched=next((row for row in reversed(doc.get("items",[]))
        if str(row.get("event_id") or "")==trend_id
        and int(row.get("revision") or 0)==rev
        and int(row.get("telegram_message_id") or 0)==message_id
        and str(row.get("status") or "").lower()=="sent"
        and isinstance(row.get("instagram"),dict)
        and row["instagram"].get("image_url")
        and row["instagram"].get("caption")),None)
    if not matched:
        call("sendMessage",{"chat_id":chat_id,"text":"El paquete ya no está disponible para Instagram.","reply_to_message_id":message_id})
        return "not_eligible"

    body={
        "source":"ttendencias","event_id":trend_id,"revision":rev,
        "telegram_message_id":message_id,
        "image_url":str(matched["instagram"]["image_url"]),
        "caption":str(matched["instagram"]["caption"]),
    }
    result={}
    for attempt in range(5):
        request=urllib.request.Request(
            endpoint+"/publish",data=json.dumps(body,ensure_ascii=False).encode("utf-8"),
            headers={"content-type":"application/json","authorization":"Bearer "+secret,
                     "user-agent":"TTActualidad-Telegram/1.0"},
            method="POST")
        try:
            # Creating media may require a remote download by Meta; a 20-second
            # limit previously hid the true outcome behind "publisher_error".
            with urllib.request.urlopen(request,timeout=55) as response:
                result=decode_instagram_publisher_response(response,getattr(response,"status",200))
        except urllib.error.HTTPError as exc:
            result=decode_instagram_publisher_response(exc,exc.code)
        except (urllib.error.URLError,TimeoutError,OSError) as exc:
            # A timeout can happen after Meta has accepted the request. Never
            # auto-retry the publishing POST when its fate is unknown.
            kind="TIMEOUT" if isinstance(exc,TimeoutError) or "timed out" in str(exc).lower() else "NETWORK_FAILURE"
            result={"state":"transport_error","error":kind,"_http_status":0}
        if str(result.get("state") or "")!="processing":
            break
        time.sleep(2+attempt)
    code=str(result.get("error") or result.get("state") or "UNKNOWN")
    http_status=int(result.get("_http_status") or 0)
    print("TT_INSTAGRAM_PUBLISH_DIAGNOSTIC="+json.dumps({
        "event_id":trend_id,"error":code[:64],
        "state":str(result.get("state") or "")[:32],
        "http_status":http_status,
        "meta_error_code":result.get("meta_error_code"),
        "meta_error_subcode":result.get("meta_error_subcode")
    },ensure_ascii=False),flush=True)

    if result.get("state")=="published":
        permalink=str(result.get("permalink") or "")
        if permalink.startswith("https://www.instagram.com/"):
            original=(message.get("reply_markup") or {}).get("inline_keyboard") or []
            keyboard=[[({"text":"📸 Publicado en Instagram","url":permalink}
                       if button.get("callback_data")==data else button) for button in row]
                       for row in original]
            if keyboard:
                try:
                    call("editMessageReplyMarkup",{
                        "chat_id":chat_id,"message_id":message_id,
                        "reply_markup":{"inline_keyboard":keyboard}})
                except Exception as exc:
                    print("TT_INSTAGRAM_BUTTON_EDIT_FAILED",type(exc).__name__,flush=True)
            # Confirmation must appear as a reply even if the button was edited.
            # A Telegram notification failure must never retry the Meta publish.
            try:
                call("sendMessage",{"chat_id":chat_id,
                    "text":"📸 Publicado en Instagram: "+permalink,
                    "reply_to_message_id":message_id})
            except Exception as exc:
                print("TT_INSTAGRAM_SUCCESS_NOTICE_FAILED",type(exc).__name__,flush=True)
        else:
            try:
                call("sendMessage",{"chat_id":chat_id,
                    "text":"Instagram confirma la publicación; enlace pendiente.",
                    "reply_to_message_id":message_id})
            except Exception as exc:
                print("TT_INSTAGRAM_SUCCESS_NOTICE_FAILED",type(exc).__name__,flush=True)
        return "published"

    reason=str(result.get("state") or "")
    if reason=="uncertain":
        txt="Publicación no confirmada. Comprueba Instagram antes de otro intento."
    elif reason=="processing":
        txt="Instagram sigue procesando la imagen. El botón permanece disponible."
    elif reason=="transport_error":
        txt="No se recibió una respuesta válida del publicador. No reintentes hasta comprobar su estado."
    else:
        txt="Instagram no confirmó la publicación. El botón sigue disponible."
    # Error/status only; do not expose request contents, access tokens or secrets.
    txt+="\\nDiagnóstico: "+code[:64]+" (HTTP "+str(http_status or "sin respuesta")+")."
    meta_code=result.get("meta_error_code")
    meta_subcode=result.get("meta_error_subcode")
    if isinstance(meta_code,int):
        txt+="\\nMeta: código "+str(meta_code)
        if isinstance(meta_subcode,int):
            txt+=", subcódigo "+str(meta_subcode)
        txt+="."
    call("sendMessage",{"chat_id":chat_id,"text":"📸 "+txt,"reply_to_message_id":message_id})
    return ("publisher_"+code.lower()[:42]+"_http"+str(http_status))[:64]


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
        if text in {"/actualizar", "/refresh"}:
            ok, _, _ = refresh_trends_now()
            if ok:
                sync_panel()
                persist_git("Actualizar manualmente Top 10 TTendencias", include_trends=True)
                call("sendMessage", {"chat_id": message["chat"]["id"], "text": "Top 10 actualizado"})
            else:
                call("sendMessage", {"chat_id": message["chat"]["id"], "text": "⚠️ No se pudo actualizar el Top 10"})
            return
    cb = update.get("callback_query")
    if not cb:
        return
    data = cb.get("data", "")
    if data.startswith("tx:"):
        route_package_callback(cb)
    elif data.startswith("toggle:"):
        toggle_trend(cb)
    elif data == "batch:text":
        submit_batch(cb, with_image=False)
    elif data == "batch:image":
        submit_batch(cb, with_image=True)
    elif data == "batch:cancel":
        cancel_batch(cb)
    elif data.startswith("explained:"):
        mark_explained(cb)
    elif data.startswith("close:"):
        close_block(cb)
    elif data == "alert:delete":
        try:
            call("deleteMessage", {
                "chat_id": cb["message"]["chat"]["id"],
                "message_id": cb["message"]["message_id"],
            })
        except Exception as e:
            print("No se pudo borrar alerta TTendencias:", e, flush=True)
        try:
            call("answerCallbackQuery", {"callback_query_id": cb["id"]})
        except Exception:
            pass
    elif data == "panel:refresh":
        # Confirmar el clic inmediatamente para que Telegram no deje el botón
        # parpadeando mientras se consultan las fuentes.
        try:
            call("answerCallbackQuery", {
                "callback_query_id": cb["id"],
                "text": "Actualizando Top 10…",
            })
        except Exception:
            pass

        # El propio callback es la referencia más fiable del panel visible.
        state = load(STATE, {})
        state["chat_id"] = cb["message"]["chat"]["id"]
        state["panel_message_id"] = cb["message"]["message_id"]
        state["panel_message_ids"] = [cb["message"]["message_id"]]
        save(STATE, state)
        ok, before, after = refresh_trends_now()
        synced = sync_panel() if ok else False
        if ok and synced:
            persist_git("Actualizar manualmente Top 10 TTendencias")
            print(f"refresh manual TTendencias: {before} -> {after}", flush=True)
        else:
            try:
                call("sendMessage", {
                    "chat_id": cb["message"]["chat"]["id"],
                    "text": "⚠️ No se pudo actualizar el Top 10",
                })
            except Exception:
                pass



def route_package_callback(callback):
    """Use the same approved Telegram package routing in web and legacy mode."""
    data = str(callback.get("data") or "")
    if data.startswith("tx:i:"):
        return handle_instagram_package_callback(callback)
    return handle_package_callback(callback)


def poll_packages(seconds=3300):
    started = time.time()
    package_state = load(PACKAGE_STATE, {"version": 1, "last_update_id": 0})
    legacy_state = load(LISTENER_STATE, {"last_update_id": 0})
    offset = max(
        int(package_state.get("last_update_id") or 0),
        int(legacy_state.get("last_update_id") or 0),
    ) + 1
    dirty = False
    last_persist = time.time()

    while time.time() - started < seconds:
        try:
            updates = call("getUpdates", {
                "offset": offset,
                "timeout": 25,
                "allowed_updates": ["callback_query", "message"],
            }) or []

            for upd in updates:
                uid = int(upd["update_id"])
                offset = max(offset, uid + 1)
                package_state["last_update_id"] = uid
                package_state["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
                save(PACKAGE_STATE, package_state)
                dirty = True

                cb = upd.get("callback_query")
                if cb and str(cb.get("data") or "").startswith("tx:"):
                    callback_data = str(cb.get("data") or "")
                    if callback_data.startswith("tx:i:"):
                        # Durable result, even if the Instagram handler raises:
                        # no silent disappearance of the selected Telegram action.
                        outcome = "not_processed"
                        try:
                            outcome = str(route_package_callback(cb) or "no_result")
                        except Exception as exc:
                            outcome = "handler_error"
                            print("TT_INSTAGRAM_CALLBACK_EXCEPTION",type(exc).__name__,flush=True)
                            message = cb.get("message") or {}
                            chat_id = (message.get("chat") or {}).get("id")
                            message_id = message.get("message_id")
                            if chat_id and message_id:
                                try:
                                    call("sendMessage",{"chat_id":chat_id,
                                        "text":"No se ha podido confirmar la solicitud de Instagram. Comprueba @ttactualidad antes de volver a pulsar.",
                                        "reply_to_message_id":message_id})
                                except Exception as notify_exc:
                                    print("TT_INSTAGRAM_CALLBACK_NOTIFY_FAILED",type(notify_exc).__name__,flush=True)
                        package_state["instagram_last_action"] = {
                            "event_id":callback_data.split(":")[2] if len(callback_data.split(":"))==4 else "",
                            "outcome":outcome[:64],
                            "updated_at":datetime.now(MADRID).isoformat(timespec="seconds"),
                        }
                        save(PACKAGE_STATE,package_state)
                        print("TT_INSTAGRAM_CALLBACK_RESULT="+outcome,flush=True)
                        persist_package_state("Registrar resultado del boton Instagram TTendencias")
                    else:
                        route_package_callback(cb)
                    dirty = False
                    last_persist = time.time()

            if dirty and time.time() - last_persist >= 10:
                persist_package_state("Actualizar offset bot paquetes TTendencias")
                dirty = False
                last_persist = time.time()

        except Exception as e:
            print("package poll error:", e, flush=True)
            time.sleep(2)

    if dirty:
        persist_package_state("Actualizar offset final bot paquetes TTendencias")


def poll(seconds=3300):
    started = time.time()
    listener_state = load(LISTENER_STATE, {"last_update_id": 0, "batch_selection": []})
    offset = int(listener_state.get("last_update_id") or 0) + 1
    last_persist = time.time()
    # El listener es también el reloj fiable del panel: refresca al arrancar
    # y después cada 15 minutos aunque el cron de GitHub se retrase o falle.
    refresh_interval = int(os.environ.get("TTENDENCIAS_REFRESH_SECONDS", "0"))
    next_refresh = time.time() if refresh_interval > 0 else float("inf")
    dirty = False

    while time.time() - started < seconds:
        try:
            now = time.time()
            if now >= next_refresh:
                ok, before, after = refresh_trends_now()
                if ok:
                    if sync_panel():
                        persist_git("Actualizar automáticamente Top 10 TTendencias", include_trends=True)
                    print(f"auto refresh TTendencias: {before} -> {after}", flush=True)
                else:
                    print(f"auto refresh TTendencias sin cambio: {before} -> {after}", flush=True)
                next_refresh = now + refresh_interval

            updates = call("getUpdates", {
                "offset": offset,
                "timeout": 25,
                "allowed_updates": ["message", "callback_query"],
            }) or []

            for upd in updates:
                offset = max(offset, int(upd["update_id"]) + 1)
                handle(upd)
                listener_state = load(LISTENER_STATE, listener_state)
                listener_state["last_update_id"] = int(upd["update_id"])
                save(LISTENER_STATE, listener_state)
                dirty = True

            if dirty and time.time() - last_persist >= 10:
                persist_git("Actualizar estado TTendencias")
                dirty = False
                last_persist = time.time()

        except Exception as e:
            print("poll error:", e, flush=True)
            time.sleep(2)

    if dirty:
        persist_git("Actualizar estado final TTendencias")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "sync"
    if mode == "listen":
        poll(int(os.environ.get("TTENDENCIAS_LISTEN_SECONDS", "3300")))
    elif mode == "package-listen":
        poll_packages(int(os.environ.get("TTENDENCIAS_LISTEN_SECONDS", "3300")))
    elif mode == "sync":
        sync_panel()
    elif mode == "force":
        sync_panel(force_new=True)
        persist_git("Recrear panel TTendencias")
    else:
        raise SystemExit("Uso: telegram_bot.py [sync|listen|package-listen|force]")
