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
EDITORIAL_QUEUE = ROOT / "editorial-queue.json"

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
        ("trends/requests.json", REQUESTS),
        ("trends/telegram-package-listener-state.json", PACKAGE_STATE),
        ("trends/explained-copy-state.json", COPY_STATE),
        ("trends/editorial-queue.json", EDITORIAL_QUEUE),
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
            if status not in {"published", "dismissed", "deleted"}:
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
                    "status", "published_at", "dismissed_at", "deleted_at", "decision_source",
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
            if str(x.get("telegram_package_status") or "").lower() in {"published", "dismissed", "deleted"}:
                local_actions[(str(x.get("id") or ""), int(x.get("revision") or 0))] = x
        for row in remote_manual.get("items", []):
            src = local_actions.get((str(row.get("id") or ""), int(row.get("revision") or 0)))
            if not src:
                continue
            for k in (
                "telegram_package_status", "telegram_package_updated_at",
                "telegram_published_at", "telegram_dismissed_at", "telegram_deleted_at",
                "telegram_decision_source",
            ):
                if k in src:
                    row[k] = src[k]
        remote_manual["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
        save(MANUAL, remote_manual)

        # Persist authoritative package decisions in the editorial queue too,
        # without replacing concurrent editor changes with a stale snapshot.
        remote_requests = load(REQUESTS, {"requests": []})
        local_requests = load(snapshots.get("trends/requests.json", Path("/nonexistent")),
                              {"requests": []})
        terminal_requests = {
            str(x.get("id") or ""): x
            for x in local_requests.get("requests", [])
            if str(x.get("id") or "") and
               str(x.get("telegram_package_status") or "").lower()
                   in {"published", "dismissed", "deleted"}
        }
        # Explicit Telegram re-explanations also have to survive the fresh
        # origin/main checkout above. The former merge kept ONLY terminal states:
        # this silently erased every tx:r request after acknowledging it.
        local_reworks = {
            str(x.get("id") or ""): x
            for x in local_requests.get("requests", [])
            if str(x.get("id") or "") and
               str(x.get("request_source") or "") == "telegram_reexplain" and
               str(x.get("status") or "").lower() in {"preparing", "update"} and
               bool(x.get("reexplain"))
        }
        request_changed = False
        remote_ids = set()
        for req in remote_requests.get("requests", []):
            rid = str(req.get("id") or "")
            remote_ids.add(rid)
            rework = local_reworks.get(rid)
            if rework and str(req.get("status") or "").lower() not in {
                "published", "dismissed", "deleted", "removed"} and (
                int(rework.get("revision") or 0) > int(req.get("revision") or 0)
                or (int(rework.get("revision") or 0) == int(req.get("revision") or 0)
                    and str(req.get("status") or "").lower() not in {"preparing", "update"})
            ):
                for key in ("status", "revision", "requested_at", "reexplain",
                            "request_source", "reexplain_instructions",
                            "rewrite_instruction", "with_image", "auto_queued",
                            "telegram_reexplain_from_revision",
                            "telegram_reexplain_from_message_id"):
                    if key in rework:
                        req[key] = rework[key]
                request_changed = True
        for rid, rework in local_reworks.items():
            if rid not in remote_ids:
                remote_requests.setdefault("requests", []).append(rework)
                request_changed = True
        for req in remote_requests.get("requests", []):
            local = terminal_requests.get(str(req.get("id") or ""))
            if not local:
                continue
            outcome = str(local.get("telegram_package_status") or "").lower()
            if (str(req.get("status") or "").lower() != outcome or
                    str(req.get("telegram_package_status") or "").lower() != outcome):
                req.update(status=outcome, telegram_package_status=outcome,
                           telegram_closed_at=local.get("telegram_closed_at"),
                           reexplain=False)
                request_changed = True
        if request_changed:
            remote_requests["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
            save(REQUESTS, remote_requests)

        # Persist re-explain work immediately, not only the request flag. A
        # successful tx:r must appear in editorial-queue.json on the same push.
        local_queue = load(snapshots.get("trends/editorial-queue.json", Path("/nonexistent")),
                           {"items": []})
        remote_queue = load(EDITORIAL_QUEUE, {"project": "TTendencias", "items": []})
        queue_items = remote_queue.setdefault("items", [])
        queue_changed = False
        for incoming in local_queue.get("items", []):
            rid = str(incoming.get("id") or "")
            if not rid or not incoming.get("reexplain") or str(incoming.get("status") or "") not in {"preparing","update"}:
                continue
            remote_req = next((r for r in remote_requests.get("requests", [])
                               if str(r.get("id") or "") == rid), None)
            if (not remote_req or str(remote_req.get("status") or "") not in {"preparing","update"}
                    or not remote_req.get("reexplain")
                    or int(remote_req.get("revision") or 0) != int(incoming.get("revision") or 0)):
                continue
            old = next((row for row in queue_items if str(row.get("id") or "") == rid), None)
            if old is None:
                queue_items.append(incoming)
                queue_changed = True
            elif int(old.get("revision") or 0) <= int(incoming.get("revision") or 0) and old != incoming:
                old.update(incoming)
                queue_changed = True
        if queue_changed:
            remote_queue["count"] = len(queue_items)
            remote_queue["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
            save(EDITORIAL_QUEUE, remote_queue)

        remote_state = load(PACKAGE_STATE, {"version": 1, "last_update_id": 0})
        local_state = load(snapshots.get("trends/telegram-package-listener-state.json", Path("/nonexistent")), {"last_update_id": 0})
        remote_state["version"] = 1
        remote_state["last_update_id"] = max(
            int(remote_state.get("last_update_id") or 0),
            int(local_state.get("last_update_id") or 0),
        )
        remote_state["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
        merge_instagram_last_action(remote_state, local_state)
        receipts=remote_state.get("technical_notices") or []
        receipt_ids={int(x.get("message_id") or 0) for x in receipts}
        for notice in local_state.get("technical_notices") or []:
            mid=int(notice.get("message_id") or 0)
            if mid and mid not in receipt_ids and notice.get("bot_authored") is True:
                receipts.append(notice)
                receipt_ids.add(mid)
        remote_state["technical_notices"]=receipts[-200:]
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
            "trends/requests.json",
            "trends/telegram-package-listener-state.json",
            "trends/explained-copy-state.json",
            "trends/editorial-queue.json",
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
    result=out.get("result")
    if method=="sendMessage" and isinstance(result,dict):
        body=str((payload or {}).get("text") or "")
        safe_prefixes=("TTendencias: solicitud /run", "TTendencias: ya hay una orden",
                       "TTendencias: no se ha podido enviar /run",
                       "Top 10 actualizado", "⚠️ No se pudo actualizar el Top 10",
                       "⚠️ No encuentro el paquete vigente",
                       "⚠️ No se pudo guardar el estado de TTendencias")
        mid=int(result.get("message_id") or 0)
        if mid>0 and body.startswith(safe_prefixes):
            registry=load(PACKAGE_STATE,{"version":1,"last_update_id":0})
            notices=registry.setdefault("technical_notices",[])
            if not any(int(x.get("message_id") or 0)==mid for x in notices):
                notices.append({"project":"ttendencias","message_id":mid,
                                "kind":"execution_ack" if "/run" in body else "status_notice",
                                "bot_authored":True,
                                "created_at":datetime.now(MADRID).isoformat()})
            registry["technical_notices"]=notices[-200:]
            save(PACKAGE_STATE,registry)
    return result


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
    """Retired: radar status changes must never create new Telegram messages.

    Only shared/telegram_readonly_delivery.py may deliver a trend card.
    Historically a change red/yellow sent T<rank> · <name> even after Borrar.
    Those alerts had no delivery ledger, so no duplicate protection applied.
    """
    return



def unpin_panels(chat_id):
    """Only unpin the historical trends panel; preserve our pinned INDEX."""
    state=load(STATE,{})
    mids={int(v) for v in (state.get("panel_message_ids") or []) if str(v).isdigit()}
    active=int(state.get("panel_message_id") or 0)
    if active:mids.add(active)
    index=load_remote_json("telegram/pinned-index-ttendencias.json",{})
    protected=int(index.get("message_id") or 0)
    for mid in sorted(m for m in mids if m>0 and m!=protected):
        try:
            call("unpinChatMessage",{"chat_id":chat_id,"message_id":mid})
        except Exception as e:
            print("No se pudo desanclar panel",mid,type(e).__name__,flush=True)


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
    for mid in sorted(ids):
        if keep is not None and int(mid) == int(keep):
            continue
        delete_panel(chat_id, mid)
    state["panel_message_ids"] = [keep] if keep else []


def sync_panel(force_new=False):
    """Retired: the compact fixed index is the only status panel.

    Legacy message IDs stay in the persisted state for safe cleanup.
    Never guess IDs or publish a replacement panel.
    """
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
                    "reply_to_message_id":message_id,
                    "reply_markup":{"inline_keyboard":[[
                        {"text":"🗑️ Borrar","callback_data":f"tx:igdel:{message_id}"}
                    ]]}})
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


def request_windows_editorial_run():
    """Solicita la pasada al listener Windows EXISTENTE mediante su rama de control.
    No modifica main ni inicia otra automatización."""
    import base64
    import secrets
    token = (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "").strip()
    if not token:
        raise RuntimeError("GitHub Actions no ha proporcionado GH_TOKEN al listener de Telegram")
    repo = os.environ.get("GITHUB_REPOSITORY", "fabricelop/europapress-rss")
    branch = "control/ttendencias-run-trigger"
    filepath = "trends/run-now-trigger.json"
    endpoint = f"https://api.github.com/repos/{repo}/contents/{filepath}"
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "ttendencias-telegram-run",
    }
    for attempt in range(4):
        url = endpoint + "?ref=" + urllib.parse.quote(branch, safe="")
        get = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(get, timeout=20) as response:
            current = json.loads(response.read().decode("utf-8"))
        doc = json.loads(base64.b64decode(current["content"]).decode("utf-8"))
        # Evitar enviar dos órdenes idénticas si el usuario repite /run.
        try:
            age = (datetime.now(ZoneInfo("UTC")) - datetime.fromisoformat(
                str(doc.get("requested_at", "")).replace("Z", "+00:00")
            )).total_seconds()
        except (ValueError, TypeError):
            age = 9999
        if doc.get("command_id") and 0 <= age < 90:
            return {"status": "already_requested", "command_id": doc["command_id"]}
        moment = datetime.now(ZoneInfo("UTC"))
        cmd = "tr-" + str(int(moment.timestamp() * 1000)) + "-tg-" + secrets.token_hex(3)
        payload = {
            "version": 2, "command_id": cmd,
            "requested_at": moment.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "mode": "manual_pc_chat", "executor": "pc_chat_ttendencias_dedicated",
            "project": "ttendencias", "launcher_arg": "tendencias",
            "task": "editorial", "auto_image_followup": False,
        }
        put = {
            "message": "TTendencias: ejecución Windows solicitada por Telegram " + cmd,
            "branch": branch, "sha": current["sha"],
            "content": base64.b64encode((json.dumps(payload, ensure_ascii=False, indent=2)+"\n").encode("utf-8")).decode("ascii"),
        }
        request = urllib.request.Request(
            endpoint, data=json.dumps(put).encode("utf-8"), headers={
                **headers, "Content-Type": "application/json",
            }, method="PUT",
        )
        try:
            with urllib.request.urlopen(request, timeout=25) as response:
                if response.status in (200, 201):
                    return {"status": "requested", "command_id": cmd}
        except urllib.error.HTTPError as exc:
            if exc.code in (409, 422) and attempt < 3:
                time.sleep(0.3 * (attempt + 1))
                continue
            raise RuntimeError("GitHub no aceptó la solicitud Windows (HTTP " + str(exc.code) + ")")
    raise RuntimeError("No se pudo registrar la orden por concurrencia")


def handle_run_command(message):
    """Ruta de /run en modo web Y en modo legacy, sin cambiar panel ni callbacks."""
    if not isinstance(message, dict):
        return False
    command = str(message.get("text") or "").strip().lower()
    if command not in ("/run", "/run@ttendenciases_bot", "/tendencias", "/tendencias@ttendenciases_bot"):
        return False
    chat = message.get("chat") or {}
    expected = str(load(STATE, {}).get("chat_id") or "")
    if str(chat.get("id") or "") != expected or str(chat.get("type") or "") != "private":
        print("TTENDENCIAS_RUN_UNAUTHORIZED_CHAT", flush=True)
        return True
    try:
        result = request_windows_editorial_run()
        print("TTENDENCIAS_RUN_ACCEPTED",result.get("command_id"),
              result.get("status"),flush=True)
    except Exception as exc:
        print("TTENDENCIAS_RUN_FAILED",type(exc).__name__,str(exc)[:200],flush=True)
    return True


def handle(update):
    state = load(STATE, {"chat_id": None, "panel_message_id": None, "last_update_id": 0, "pending": {}})
    message = update.get("message")
    if message:
        if handle_run_command(message):
            return
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



def handle_instagram_confirmation_delete(callback):
    """Delete the Instagram success notice and its original Telegram package only."""
    message=callback.get("message") or {}
    chat_id=int((message.get("chat") or {}).get("id") or 0)
    confirmation_id=int(message.get("message_id") or 0)
    data=str(callback.get("data") or "")
    original_str=data.removeprefix("tx:igdel:")
    original_id=int(original_str) if original_str.isdecimal() else 0
    reply_id=int((message.get("reply_to_message") or {}).get("message_id") or 0)
    notice=str(message.get("text") or "")
    state=load(STATE,{})
    allowed_chat=int(state.get("chat_id") or 0)
    if not allowed_chat:
        state=load_remote_json("trends/telegram-bot-state.json",{})
        allowed_chat=int(state.get("chat_id") or 0)
    if (not allowed_chat or allowed_chat!=chat_id or not original_id
            or original_id==confirmation_id or confirmation_id<=0
            or (reply_id and reply_id!=original_id)
            or not notice.startswith("📸 Publicado en Instagram: https://www.instagram.com/")):
        call("answerCallbackQuery",{
            "callback_query_id":callback["id"],"text":"Confirmación no válida.",
            "show_alert":True})
        return "invalid_confirmation"

    # Delete the original first, leaving the notice/button if that fails.
    try:
        call("deleteMessage",{"chat_id":chat_id,"message_id":original_id})
    except Exception as exc:
        if "message to delete not found" not in str(exc).lower():
            call("answerCallbackQuery",{
                "callback_query_id":callback["id"],"text":"No se pudo borrar el original.",
                "show_alert":True})
            return "original_delete_failed"
    try:
        call("deleteMessage",{"chat_id":chat_id,"message_id":confirmation_id})
    except Exception as exc:
        if "message to delete not found" not in str(exc).lower():
            print("TT_INSTAGRAM_CONFIRMATION_DELETE_FAILED",type(exc).__name__,flush=True)
            return "confirmation_delete_failed"
    try:
        call("answerCallbackQuery",{"callback_query_id":callback["id"],"text":"Mensajes borrados."})
    except Exception:
        pass
    return "deleted"


def handle_readonly_delete(callback):
    """Borrar sin marcar publicado/desestimado y bloquear reentrega."""
    data=str(callback.get("data") or "")
    parts=data.split(":")
    if len(parts)!=4 or parts[:2]!=["tx","b"]:
        return False
    tid=parts[2]
    try:rev=int(parts[3])
    except (ValueError,TypeError):return False
    message=callback.get("message") or {}
    mid=int(message.get("message_id") or 0)
    chat=int((message.get("chat") or {}).get("id") or 0)
    state=load_remote_json("trends/telegram-bot-state.json",load(STATE,{}))
    if not chat or chat!=int(state.get("chat_id") or 0):
        return "unauthorized"
    ledger=load_remote_json("trends/telegram-image-deliveries.json",load(IMAGE_DELIVERIES,{"items":[]}))
    linked=[x for x in ledger.get("items",[])
            if str(x.get("event_id") or "")==tid
            and int(x.get("revision") or 0)==rev
            and str(x.get("status") or "").lower()=="sent"]
    if not linked or not any(int(x.get("telegram_message_id") or 0)==mid for x in linked):
        try:call("answerCallbackQuery",{"callback_query_id":callback["id"],"text":"Mensaje no disponible."})
        except Exception:pass
        return "not_found"
    now=datetime.now(MADRID).isoformat(timespec="seconds")
    mids=set()
    for row in linked:
        row.update({"status":"deleted","deleted_at":now,"decision_source":"telegram_delete"})
        for field in ("telegram_message_id","archive_telegram_message_id"):
            value=int(row.get(field) or 0)
            if value:mids.add(value)
    manual=load_remote_json("trends/telegram-manual-explained.json",load(MANUAL,{"items":[]}))
    for row in manual.get("items",[]):
        if str(row.get("id") or "")==tid and int(row.get("revision") or 0)==rev:
            row.update({"telegram_package_status":"deleted","telegram_deleted_at":now})
    # The visible Telegram card may belong to an older editorial revision:
    # close the whole subject, otherwise the next radar pass resends it.
    requests_doc=load_remote_json("trends/requests.json",load(REQUESTS,{"requests":[]}))
    for request in requests_doc.get("requests",[]):
        if str(request.get("id") or "")==tid:
            request.update(status="deleted",telegram_package_status="deleted",
                           telegram_closed_at=now,reexplain=False)
    save(REQUESTS,requests_doc)
    save(IMAGE_DELIVERIES,ledger)
    save(MANUAL,manual)
    if not persist_package_state("Borrar tarjeta informativa TTendencias"):
        try:call("answerCallbackQuery",{"callback_query_id":callback["id"],
                                        "text":"No se pudo guardar el borrado.","show_alert":True})
        except Exception:pass
        return "persistence_failed"
    for value in mids:
        try:call("deleteMessage",{"chat_id":chat,"message_id":value})
        except Exception as exc:
            print("TTENDENCIAS_DELETE_RETRY",value,type(exc).__name__,flush=True)
    try:call("answerCallbackQuery",{"callback_query_id":callback["id"],"text":"Borrada de Telegram y Listas."})
    except Exception:pass
    return "deleted"


def handle_readonly_reexplain(callback, instruction=""):
    """Persist tx:r and editorial replies through the SAME active listener.

    The old listener consumed tx:r via getUpdates but did not handle it; the
    separate native-poller had the implementation, but could not safely run
    concurrently because Telegram distributes updates across consumers.
    """
    data = str(callback.get("data") or "")
    parts = data.split(":")
    if len(parts) != 4 or parts[:2] != ["tx", "r"]:
        return "invalid_reexplain"
    tid = parts[2]
    try:
        rev = int(parts[3])
    except (ValueError, TypeError):
        return "invalid_revision"
    msg = callback.get("message") or {}
    chat_obj = msg.get("chat") or {}
    chat_id = str(chat_obj.get("id") or "")
    sender = str((callback.get("from") or {}).get("id") or "")
    allowed = str(load_remote_json("trends/telegram-bot-state.json",
                                  load(STATE, {})).get("chat_id") or "")
    if not allowed or chat_id != allowed or str(chat_obj.get("type") or "") != "private" or sender != allowed:
        print("TTENDENCIAS_REEXPLAIN_UNAUTHORIZED", flush=True)
        return "unauthorized"
    mid = int(msg.get("message_id") or 0)
    ledger = load_remote_json("trends/telegram-image-deliveries.json",
                              load(IMAGE_DELIVERIES, {"items": []}))
    rows = [x for x in ledger.get("items", [])
            if str(x.get("event_id") or "") == tid]
    active = [x for x in rows
              if int(x.get("revision") or 0) == rev
              and str(x.get("status") or "").lower() == "sent"
              and mid in {int(x.get("telegram_message_id") or 0),
                          int(x.get("archive_telegram_message_id") or 0)}]
    if not active or any(str(x.get("status") or "").lower() in
                         {"deleted", "dismissed", "published", "removed", "delete_pending"}
                         for x in rows):
        print("TTENDENCIAS_REEXPLAIN_NOT_ACTIVE", tid, rev, mid, flush=True)
        return "not_active"
    requests_doc = load_remote_json("trends/requests.json", load(REQUESTS, {"requests": []}))
    request = next((x for x in requests_doc.get("requests", [])
                    if str(x.get("id") or "") == tid), None)
    original_tid = tid
    # Clicking any sibling of an editorial group must request a SINGLE
    # re-explanation of the canonical leader, not a new copy per sibling.
    leader_id = str((request or {}).get("group_leader_id") or
                    active[0].get("group_leader_id") or "").strip()
    group_id = str((request or {}).get("explanation_group_id") or
                   (request or {}).get("group_id") or
                   active[0].get("group_id") or "").strip()
    if leader_id and leader_id != tid and group_id:
        leader_req = next((x for x in requests_doc.get("requests", [])
                           if str(x.get("id") or "") == leader_id
                           and str(x.get("explanation_group_id") or x.get("group_id") or "") == group_id), None)
        leader_live = any(str(x.get("event_id") or "") == leader_id
                          and str(x.get("status") or "").lower() == "sent"
                          for x in ledger.get("items", []))
        if leader_req and leader_live:
            tid, request = leader_id, leader_req
    if request is None:
        # Recover the original title/id even if an older request was pruned.
        request = {"id": tid, "name": str(active[0].get("name") or
                      active[0].get("title") or "").strip(), "revision": rev}
        if not request["name"]:
            return "request_missing"
        requests_doc.setdefault("requests", []).append(request)
    if str(request.get("status") or "").lower() in {
            "published", "deleted", "dismissed", "removed"}:
        return "closed"
    if str(request.get("status") or "").lower() in {"preparing", "update"} and request.get("reexplain"):
        return "already_pending"
    now = datetime.now(MADRID).isoformat(timespec="seconds")
    details = str(instruction or "").strip()[:600] or (
        "Vuelve a investigar esta tendencia con información ACTUALIZADA. "
        "Si se anunciaba un partido o acontecimiento futuro, comprueba "
        "si ya terminó y explica el resultado confirmado, no la previa.")
    request.update(status="update", revision=max(int(request.get("revision") or 0), rev)+1,
                   requested_at=now, reexplain=True, request_source="telegram_reexplain",
                   reexplain_instructions=details, rewrite_instruction=details,
                   with_image=False, auto_queued=False,
                   telegram_reexplain_from_revision=rev,
                   telegram_reexplain_from_message_id=mid)
    requests_doc["updated_at"] = now
    save(REQUESTS, requests_doc)
    # Queue on the same transaction: the previous implementation waited for
    # an unrelated radar run and left /Reexplicar apparently inert.
    queue_doc = load_remote_json("trends/editorial-queue.json",
                                 load(EDITORIAL_QUEUE, {"project":"TTendencias","items":[]}))
    work = queue_doc.setdefault("items", [])
    work[:] = [q for q in work if str(q.get("id") or "") != tid]
    work.append({
        "id": tid, "name": request.get("name"), "rank": request.get("rank"),
        "status": "update", "revision": request["revision"],
        "requested_at": now, "reexplain": True, "auto_queued": False,
        "with_image": False, "rewrite_with_image": False,
        "rewrite_instruction": details, "task": "explain",
        "group_id": group_id or request.get("group_id"),
        "group_leader_id": tid if group_id else None,
        "requested_together": [x.get("name") for x in requests_doc.get("requests", [])
                               if group_id and
                               str(x.get("explanation_group_id") or x.get("group_id") or "") == group_id],
    })
    queue_doc["count"] = len(work)
    queue_doc["updated_at"] = now
    save(EDITORIAL_QUEUE, queue_doc)
    if not persist_package_state("Encolar nueva explicacion TTendencias desde Telegram"):
        return "persistence_failed"
    print("TTENDENCIAS_REEXPLAIN_PERSISTED", tid, request["revision"], flush=True)
    return "queued"


def notify_reexplain(result, chat_id, callback_id=None):
    labels = {
        "queued": "Nueva explicación solicitada y guardada en la cola editorial.",
        "already_pending": "Ya hay una reexplicación pendiente; no la duplico.",
        "not_active": "Esta tarjeta ya no está activa o no coincide con la versión original.",
        "closed": "Esta tendencia está cerrada; no la volveré a enviar.",
        "request_missing": "No encuentro el título original; no se ha creado otra tendencia.",
        "persistence_failed": "No se pudo guardar la nueva explicación. Vuelve a intentarlo.",
    }
    label = labels.get(result, "No se pudo procesar la reexplicación.")
    if callback_id:
        try:
            call("answerCallbackQuery", {"callback_query_id": callback_id,
                                          "text": label[:190],
                                          "show_alert": result not in {"queued", "already_pending"}})
            return
        except Exception:
            pass
    try:
        call("sendMessage", {"chat_id": chat_id, "text": "TTendencias: " + label})
    except Exception:
        pass


def handle_index_autoheal(callback):
    """Only the private owner can request the bounded GitHub autocorrection."""
    message=callback.get("message") or {}
    chat_id=int((message.get("chat") or {}).get("id") or 0)
    sender=int((callback.get("from") or {}).get("id") or 0)
    state=load_remote_json("trends/telegram-bot-state.json",load(STATE,{}))
    authorized=int(state.get("chat_id") or 0)
    if not authorized or chat_id!=authorized or sender!=authorized:
        call("answerCallbackQuery",{"callback_query_id":callback["id"],
              "text":"Solo el propietario puede solicitar reparación.",
              "show_alert":True})
        return "unauthorized"
    token=(os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "").strip()
    if not token:
        call("answerCallbackQuery",{"callback_query_id":callback["id"],
              "text":"GitHub no está disponible; reintenta.",
              "show_alert":True})
        return "unavailable"
    url="https://api.github.com/repos/fabricelop/europapress-rss/actions/workflows/tt-autorepair.yml/dispatches"
    payload=json.dumps({"ref":"main","inputs":{"force":"true"}}).encode()
    req=urllib.request.Request(url,method="POST",data=payload,headers={
        "Authorization":"Bearer "+token,"Content-Type":"application/json",
        "Accept":"application/vnd.github+json","User-Agent":"ttendencias-autoheal"})
    try:
        with urllib.request.urlopen(req,timeout=25) as result:
            if result.status!=204:raise RuntimeError("dispatch_not_accepted")
    except Exception as exc:
        print("TT_INDEX_AUTOREPAIR_FAILED",type(exc).__name__,flush=True)
        call("answerCallbackQuery",{"callback_query_id":callback["id"],
              "text":"No se pudo solicitar la revisión. Reintenta.",
              "show_alert":True})
        return "failed"
    call("answerCallbackQuery",{"callback_query_id":callback["id"],
          "text":"Autocorrección solicitada; comprobaré ambos bots."})
    print("TT_INDEX_AUTOREPAIR_REQUESTED ttendencias",flush=True)
    return "requested"


def route_package_callback(callback):
    """Use the same approved Telegram package routing in web and legacy mode."""
    data = str(callback.get("data") or "")
    if data == "tx:heal":
        return handle_index_autoheal(callback)
    if data.startswith("tx:i:"):
        return "instagram_retired"
    if data.startswith("tx:r:"):
        result = handle_readonly_reexplain(callback)
        notify_reexplain(result, (callback.get("message") or {}).get("chat", {}).get("id"),
                         callback.get("id"))
        return result
    if data.startswith("tx:b:"):
        return handle_readonly_delete(callback)
    if data.startswith("tx:igdel:"):
        return handle_instagram_confirmation_delete(callback)
    return "legacy_publication_retired" if data.startswith(("tx:p:","tx:d:")) else handle_package_callback(callback)


def refresh_live_pinned_index():
    """Keep the pinned index current without a scheduled GitHub workflow."""
    script="shared/telegram_pinned_index.py"
    if not os.path.isfile(script):
        print("TT_PINNED_INDEX_SCRIPT_MISSING ttendencias",flush=True)
        return
    env=dict(os.environ,TT_PINNED_INDEX_REMOTE="1")
    try:
        result=subprocess.run([sys.executable,script,"ttendencias"],
                              env=env,capture_output=True,text=True,timeout=100)
        print("TT_PINNED_INDEX_LISTENER ttendencias",
              "OK" if result.returncode==0 else "ERROR",
              (result.stdout+result.stderr)[-1000:],flush=True)
    except Exception as exc:
        print("TT_PINNED_INDEX_LISTENER_FAILED ttendencias",
              type(exc).__name__,flush=True)


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
    last_index_refresh = 0.0

    while time.time() - started < seconds:
        try:
            if time.monotonic()-last_index_refresh>=180:
                last_index_refresh=time.monotonic()
                refresh_live_pinned_index()
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
                newer=load(PACKAGE_STATE,{})
                receipts=newer.get("technical_notices") or []
                known={int(x.get("message_id") or 0) for x in receipts}
                for entry in package_state.get("technical_notices") or []:
                    mid=int(entry.get("message_id") or 0)
                    if mid and mid not in known:
                        receipts.append(entry)
                        known.add(mid)
                package_state["technical_notices"]=receipts[-200:]
                save(PACKAGE_STATE, package_state)
                dirty = True

                if handle_run_command(upd.get("message")):
                    package_state=load(PACKAGE_STATE,package_state)
                    continue

                # Re-explain by replying directly to the delivered card.
                reply = upd.get("message") or {}
                parent = reply.get("reply_to_message") or {}
                if parent and str(reply.get("text") or "").strip():
                    target = int(parent.get("message_id") or 0)
                    if target:
                        state = load_remote_json("trends/telegram-image-deliveries.json",
                                                 load(IMAGE_DELIVERIES, {"items": []}))
                        linked = next((x for x in reversed(state.get("items", []))
                          if target in {int(x.get("telegram_message_id") or 0),
                                        int(x.get("archive_telegram_message_id") or 0)}
                          and str(x.get("status") or "").lower() == "sent"), None)
                        if linked:
                            fake = {"data": "tx:r:" + str(linked.get("event_id")) + ":" +
                                str(int(linked.get("revision") or 0)),
                                "message": {"chat": reply.get("chat") or {},
                                            "message_id": target},
                                "from": reply.get("from") or {}}
                            outcome = handle_readonly_reexplain(fake, reply.get("text"))
                            notify_reexplain(outcome, (reply.get("chat") or {}).get("id"))
                            dirty = False
                            last_persist = time.time()
                            continue

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
