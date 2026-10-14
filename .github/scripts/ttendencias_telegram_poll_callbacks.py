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
REQUESTS = Path("trends/requests.json")
OFFSET = Path("trends/telegram-native-callback-offset.json")
ACKS = Path("/tmp/tt-tr-telegram-callback-acks.json")
PATTERN = re.compile(r"^tx:([bdrp]):([A-Za-z0-9_-]{5,80}):(\d{1,8})$")


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


def process(updates, allowed_chat, ledger, decisions, offset, requests=None):
    if requests is None:
        requests = {"requests": []}
    changed = False
    acknowledgements = []
    current = int(offset.get("last_update_id") or 0)
    for item in sorted(updates, key=lambda x: int(x.get("update_id") or 0)):
        uid = int(item.get("update_id") or 0)
        if uid <= current:
            continue
        current = uid
        cq = item.get("callback_query") or {}
        qid = str(cq.get("id") or "")
        reply = item.get("message") or {}
        if cq:
            match = PATTERN.fullmatch(str(cq.get("data") or ""))
            if not match:continue
            msg = cq.get("message") or {}
            chat = msg.get("chat") or {}
            chat_id = str(chat.get("id") or "")
            sender = str((cq.get("from") or {}).get("id") or "")
            if not allowed_chat or chat_id != allowed_chat or (str(chat.get("type") or "")=="private" and sender!=chat_id):
                continue
            raw_action, event_id, rev = match.groups()
            rev = int(rev)
            mid = int(msg.get("message_id") or 0)
        elif reply and reply.get("reply_to_message"):
            chat = reply.get("chat") or {}
            chat_id = str(chat.get("id") or "")
            sender = str((reply.get("from") or {}).get("id") or "")
            if not allowed_chat or chat_id!=allowed_chat or sender!=chat_id:
                continue
            original = int((reply.get("reply_to_message") or {}).get("message_id") or 0)
            matched_reply = next((x for x in reversed(ledger.get("items", []))
                if str(x.get("status") or "")=="sent" and original>0
                and original in {int(x.get("telegram_message_id") or 0),
                                 int(x.get("archive_telegram_message_id") or 0)}),None)
            if not matched_reply:continue
            raw_action, event_id, rev = "r",str(matched_reply["event_id"]),int(matched_reply.get("revision") or 0)
            mid=original
        else:
            continue
        matched = [x for x in ledger.get("items", [])
                   if str(x.get("event_id") or "") == event_id
                   and int(x.get("revision") or 0) == rev
                   and mid > 0 and mid in {
                       int(x.get("telegram_message_id") or 0),
                       int(x.get("archive_telegram_message_id") or 0)
                   }]
        status = "published" if raw_action == "p" else "deleted"
        if not matched:
            acknowledgements.append({"callback_id": qid,
                                    "text": "No se encontró el paquete exacto; no se borró nada.",
                                    "alert": True})
            continue
        if raw_action == "r":
            req = next((x for x in requests.get("requests", [])
                        if str(x.get("id") or "")==event_id),None)
            if req is None:
                acknowledgements.append({"callback_id":qid,
                    "text":"No encuentro la solicitud editorial; no se ha creado otra tendencia.",
                    "alert":True})
                continue
            if str(req.get("status") or "") in {"preparing","update"} and req.get("reexplain"):
                acknowledgements.append({"callback_id":qid,
                    "text":"La reexplicación ya está pendiente.","alert":False})
                continue
            # A button uses a generic update request. A reply supplies useful
            # context, e.g. "acabó Elche-Celta, comprueba el resultado final".
            details=str(reply.get("text") or reply.get("caption") or "").strip() if not cq else ""
            instruction=details[:600] or (
                "Investiga de nuevo esta tendencia con información ACTUAL. "
                "Si se anunciaba un partido o acontecimiento futuro, verifica "
                "si ya terminó y explica su resultado confirmado, no la previa.")
            req.update(status="preparing",revision=int(req.get("revision") or 0)+1,
                requested_at=stamp(),reexplain=True,request_source="telegram_reexplain",
                reexplain_instructions=instruction,rewrite_instruction=instruction,
                with_image=False,auto_queued=False,telegram_reexplain_from_revision=rev,
                telegram_reexplain_from_message_id=mid)
            requests["updated_at"]=stamp()
            changed=True
            acknowledgements.append({"callback_id":qid,
                "text":"Reexplicación en cola: revisaré los hechos actuales en la siguiente pasada editorial.",
                "alert":False})
            continue
        terminal = {"published"} if status == "published" else {"delete_pending", "deleted"}
        # The clicked message proves ownership of this event/revision. Close
        # ALL still-active companion messages of the same event, not only the
        # clicked photo, to prevent orphaned images in the Telegram chat.
        companions = [x for x in ledger.get("items", [])
                      if str(x.get("event_id") or "") == event_id
                      and str(x.get("status") or "") == "sent"]
        already = len(companions) == 0
        if not already:
            for row in companions:
                row["status"] = "published" if status == "published" else "delete_pending"
                row["decision_source"] = "telegram_bot_native_poll"
                row["updated_at"] = stamp()
                if status == "published":
                    row["published_at"] = stamp()
            ledger["updated_at"] = stamp()
            changed = True
        # A Telegram decision closes the editorial request as well as the
        # delivery ledger; otherwise auto-queue may resurrect old revisions.
        # For an explicit grouped package, the single Telegram decision also
        # closes only those follower requests that persist the same leader/group.
        group_member_ids = {event_id}
        group_ids = set()
        for row in matched:
            group_id = str(row.get("group_id") or "")
            if group_id:
                group_ids.add(group_id)
            for member_id in row.get("group_member_ids") or []:
                member_id = str(member_id or "")
                if member_id:
                    group_member_ids.add(member_id)
        for req in requests.get("requests", []):
            req_id = str(req.get("id") or "")
            if req_id not in group_member_ids:
                continue
            if req_id != event_id:
                req_leader = str(req.get("group_leader_id") or "")
                req_group = str(req.get("explanation_group_id") or req.get("group_id") or "")
                if req_leader != event_id or (group_ids and req_group not in group_ids):
                    continue
            if (str(req.get("status") or "").lower() != status
                    or str(req.get("telegram_package_status") or "").lower() != status):
                req["status"] = status
                req["telegram_package_status"] = status
                req["telegram_closed_at"] = stamp()
                req["telegram_closed_revision"] = int(req.get("revision") or rev)
                req["telegram_decision_source"] = (
                    "telegram_bot_native_poll_group"
                    if req_id != event_id else "telegram_bot_native_poll"
                )
                req["reexplain"] = False
                requests["updated_at"] = stamp()
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
    requests = read(REQUESTS, {"requests": []})
    params = urllib.parse.urlencode({
        "offset": int(offset.get("last_update_id") or 0) + 1,
        "limit": 100, "timeout": 0,
        "allowed_updates": json.dumps(["callback_query", "message"])
    })
    base = "https://api.telegram.org/bot" + token + "/"
    result = request_json(base + "getUpdates?" + params)
    if not result.get("ok"):
        raise RuntimeError("Telegram getUpdates no respondió correctamente")
    updates = result.get("result") or []
    # Este consumidor también puede recibir /run antes que el listener principal.
    # Ambos comparten la misma protección anti-duplicados en la rama control.
    fresh_commands = [
        u.get("message") for u in updates
        if int(u.get("update_id") or 0) > int(offset.get("last_update_id") or 0)
        and isinstance(u.get("message"), dict)
        and str((u.get("message") or {}).get("text") or "").strip().lower()
            in ("/run", "/run@ttendenciases_bot", "/tendencias", "/tendencias@ttendenciases_bot")
    ]
    if fresh_commands:
        sys.path.insert(0, str(ROOT))
        from trends.telegram_bot import handle_run_command
        for message in fresh_commands:
            handle_run_command(message)
    changed, acks = process(updates, chat, ledger, decisions, offset, requests)
    if changed:
        write(LEDGER, ledger)
        write(DECISIONS, decisions)
        write(REQUESTS, requests)
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
    # Companion picture / different revision gets closed with verified click.
    copy={"event_id":"abc123xyz","revision":1,"telegram_message_id":5555,"status":"sent"}
    ledger["items"].append(copy)
    companion_click={"update_id":102,"callback_query":{"id":"anothercallback123",
        "data":"tx:b:abc123xyz:2","from":{"id":456},
        "message":{"message_id":1234,"chat":{"id":456,"type":"private"}}}}
    done,_=process([companion_click],"456",ledger,decisions,state)
    assert done and copy["status"]=="delete_pending"
    bad = {"update_id":101,"callback_query":{"id":"badcallback321",
        "data":"tx:b:abc123xyz:2","from":{"id":999},
        "message":{"message_id":1234,"chat":{"id":999,"type":"private"}}}}
    process([bad], "456", ledger, decisions, state)
    assert ledger["items"][0]["status"] == "delete_pending"
    # A delete on one explicit grouped Telegram package closes the leader
    # and only its persisted follower requests, preserving each own revision.
    group_ledger={"items":[{"event_id":"leader123","revision":0,
        "telegram_message_id":2234,"status":"sent","group_id":"grp-1",
        "group_member_ids":["leader123","member456"]}]}
    group_reqs={"requests":[
        {"id":"leader123","revision":0,"name":"Líder","status":"explained",
         "group_id":"grp-1","group_leader_id":"leader123"},
        {"id":"member456","revision":1,"name":"Miembro","status":"explained",
         "group_id":"grp-1","group_leader_id":"leader123",
         "grouped_into_existing_card":True},
        {"id":"other789","revision":0,"name":"Otro","status":"explained",
         "group_id":"grp-2","group_leader_id":"other789"}]}
    group_state={"last_update_id":0}
    group_update={"update_id":9,"callback_query":{"id":"groupdelete123",
        "data":"tx:b:leader123:0","from":{"id":456},
        "message":{"message_id":2234,"chat":{"id":456,"type":"private"}}}}
    group_changed,_=process([group_update],"456",group_ledger,{"items":[]},group_state,group_reqs)
    assert group_changed
    by_group_id={x["id"]:x for x in group_reqs["requests"]}
    assert by_group_id["leader123"]["status"]=="deleted"
    assert by_group_id["member456"]["status"]=="deleted"
    assert by_group_id["member456"]["telegram_closed_revision"]==1
    assert by_group_id["other789"]["status"]=="explained"

    # A request from a verified message schedules ONE new editorial revision.
    reqs={"requests":[{"id":"abc123xyz","revision":2,"name":"Elche",
                         "status":"explained","explanation":"Previa de las 14:00."}]}
    fresh_ledger={"items":[{"event_id":"abc123xyz","revision":2,
        "telegram_message_id":1234,"status":"sent"}]}
    fresh_state={"last_update_id":0}
    rework={"update_id":10,"callback_query":{"id":"rew123",
        "data":"tx:r:abc123xyz:2","from":{"id":456},
        "message":{"message_id":1234,"chat":{"id":456,"type":"private"}}}}
    valid,acks=process([rework],"456",fresh_ledger,{"items":[]},fresh_state,reqs)
    assert valid and reqs["requests"][0]["status"]=="preparing"
    assert reqs["requests"][0]["revision"]==3 and reqs["requests"][0]["reexplain"]
    assert fresh_ledger["items"][0]["status"]=="sent"
    repeat={"update_id":11,"callback_query":{**rework["callback_query"],"id":"rew124"}}
    process([repeat],"456",fresh_ledger,{"items":[]},fresh_state,reqs)
    assert reqs["requests"][0]["revision"]==3
    # A reply to the original card carries a specific editorial instruction.
    reqs2={"requests":[{"id":"abc123xyz","revision":2,"name":"Elche","status":"explained"}]}
    reply={"update_id":15,"message":{"message_id":700,"text":"El partido ya terminó: revisa el marcador",
        "from":{"id":456},"chat":{"id":456,"type":"private"},
        "reply_to_message":{"message_id":1234}}}
    process([reply],"456",fresh_ledger,{"items":[]},{"last_update_id":0},reqs2)
    assert "partido ya terminó" in reqs2["requests"][0]["reexplain_instructions"]
    assert reqs2["requests"][0]["revision"]==3
    forbidden={"update_id":16,"message":{**reply["message"],"from":{"id":999}}}
    process([forbidden],"456",fresh_ledger,{"items":[]},{"last_update_id":0},reqs2)
    assert reqs2["requests"][0]["revision"]==3
    print("TTENDENCIAS_TELEGRAM_CALLBACK_SELFTEST_OK")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        selftest()
    else:
        live()
