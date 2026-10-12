#!/usr/bin/env python3
"""Single pinned, live index for the two private TT Telegram bots.

A bot can't retrospectively enumerate a private chat. The authoritative
sources are its own delivery ledger and the editorial queue. An existing
index is edited in place; never spam the chat with repeated index copies.
"""
import argparse
import hashlib
import html
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT=Path(__file__).resolve().parents[1]
MAX_TEXT=4096
PROJECTS={
    "ttittulares":{
        "bot_token":"TELEGRAM_BOT_TOKEN","chat":"TELEGRAM_CHAT_ID",
        "ledger":"telegram/ttittulares-deliveries.json",
        "queue":"ttittulares/editorial-queue.json",
        "state":"telegram/pinned-index-ttittulares.json",
        "label":"TTiTTulares"},
    "ttendencias":{
        "bot_token":"TTENDENCIAS_BOT_TOKEN","chat":"TTENDENCIAS_CHAT_ID",
        "ledger":"trends/telegram-image-deliveries.json",
        "queue":"trends/editorial-queue.json",
        "state":"telegram/pinned-index-ttendencias.json",
        "label":"TTendencias"},
}

def read(path,default):
    try:return json.loads((ROOT/path).read_text(encoding="utf-8"))
    except (OSError,ValueError):return default

def write(path,data):
    dest=ROOT/path
    dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(json.dumps(data,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def moment(value):
    try:
        dt=datetime.fromisoformat(str(value or "").replace("Z","+00:00"))
        if dt.tzinfo is None:dt=dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except (ValueError,TypeError):return None

def shorten(value,n=82):
    value=" ".join(str(value or "").split())
    return value if len(value)<=n else value[:n-1].rstrip()+"…"

def active_records(project):
    conf=PROJECTS[project]
    checkpoint=read("telegram/lifecycle-baseline.json",{})
    baseline=(checkpoint.get("project_state") or {}).get(project,{})
    watermark=int(baseline.get("historic_max_message_id") or 0)
    cutoff=moment(checkpoint.get("activated_at"))
    protected={str(x) for x in baseline.get("preserve_pending_ids",[])}
    ledger=read(conf["ledger"],{"items":[]})
    final=[]
    pending={}
    for entry in ledger.get("items",[]):
        mid=int(entry.get("telegram_message_id") or 0)
        if mid<=watermark or str(entry.get("status") or "").lower()!="sent":
            continue
        if not mid:continue
        event_id=str(entry.get("event_id") or "")
        title=shorten(entry.get("title") or entry.get("name") or event_id)
        row={"id":event_id,"title":title,"mid":mid,
             "at":entry.get("delivered_at") or entry.get("updated_at") or ""}
        if entry.get("final") is True:
            final.append(row)
        else:
            pending[event_id]=row
    queue=read(conf["queue"],{"items":[]})
    for entry in queue.get("items",[]):
        status=str(entry.get("status") or "").lower()
        if status not in {"preparing","update","processing","ready","in_progress"}:
            continue
        event_id=str(entry.get("id") or entry.get("event_id") or "")
        if not event_id or event_id in pending or any(x["id"]==event_id for x in final):
            continue
        at=entry.get("requested_at") or entry.get("selected_at") or queue.get("updated_at")
        if cutoff and event_id not in protected:
            start=moment(at)
            if start is None or start<=cutoff:continue
        pending[event_id]={"id":event_id,
                           "title":shorten(entry.get("name") or entry.get("title") or event_id),
                           "mid":0,"at":at}
    # TTiTTulares may have selected PROCESSING entries before JIT queue is written.
    if project=="ttittulares":
        status_doc=read("ttittulares/status.json",{})
        for entry in status_doc.get("processing_items",[]):
            event_id=str(entry.get("event_id") or "")
            if not event_id or event_id in pending or any(x["id"]==event_id for x in final):
                continue
            start=moment(entry.get("selected_at"))
            if cutoff and (start is None or start<=cutoff):continue
            pending[event_id]={"id":event_id,
                               "title":shorten(entry.get("title") or event_id),
                               "mid":0,"at":entry.get("selected_at")}
    # Single current card per event; prefer newest Telegram message id.
    latest={}
    for row in final:
        event_id=row["id"]
        if event_id not in latest or latest[event_id]["mid"]<row["mid"]:
            latest[event_id]=row
    final=sorted(latest.values(),key=lambda x:x["mid"],reverse=True)
    pending=[row for k,row in pending.items() if k not in latest]
    pending.sort(key=lambda x:(str(x["at"]),x["title"]))
    return final,pending

def render(project,bot_id):
    conf=PROJECTS[project]
    ready,pending=active_records(project)
    first=f"LISTAS: {len(ready)}  |  EN ELABORACIÓN: {len(pending)}"
    header=f"{first}\n<b>{conf['label']} · índice fijado</b>\n"
    ready_lines=[]
    for item in ready:
        # Telegram private conversations have no t.me/c/post public link.
        # tg://openmessage jumps to a bot's private message on supported apps.
        # Include #id in visible text for clients that only open the chat.
        label=html.escape(shorten(item["title"],95))
        direct=(f"tg://openmessage?user_id={bot_id}&amp;"
                f"message_id={item['mid']}")
        ready_lines.append(f"• <a href=\"{direct}\">{label} ↗</a> · #{item['mid']}")
    pending_lines=[f"• {html.escape(shorten(x['title'],95))}"+
                   ("" if x["mid"] else " · pendiente de Telegram")
                   for x in pending]
    chunks=[header,"\n<b>LISTAS</b>"]
    room=MAX_TEXT-100
    count_shown=0
    for x in ready_lines:
        if len("\n".join(chunks+[x]))>=room:break
        chunks.append(x)
        count_shown+=1
    if not ready:chunks.append("• Ninguna")
    if count_shown<len(ready):chunks.append(f"… y {len(ready)-count_shown} más")
    chunks.append("\n<b>EN ELABORACIÓN</b>")
    count_pending=0
    for x in pending_lines:
        if len("\n".join(chunks+[x]))>=room:break
        chunks.append(x)
        count_pending+=1
    if not pending:chunks.append("• Ninguna")
    if count_pending<len(pending):chunks.append(f"… y {len(pending)-count_pending} más")
    chunks.append("\n<i>Se actualiza sin crear nuevos índices. Borrar desde Telegram cierra cada entrada.</i>")
    text="\n".join(chunks)
    assert len(text)<=MAX_TEXT
    return text,ready,pending

class TelegramError(RuntimeError):
    def __init__(self,method,description):
        super().__init__(f"{method}: {description}")
        self.method=method
        self.description=description

def telegram(token,method,data):
    payload=json.dumps(data,ensure_ascii=False).encode()
    req=Request("https://api.telegram.org/bot"+token+"/"+method,
                data=payload,headers={"Content-Type":"application/json"})
    try:
        with urlopen(req,timeout=25) as response:
            answer=json.load(response)
    except HTTPError as exc:
        body=exc.read().decode("utf-8",errors="replace")[:800]
        raise TelegramError(method,body) from exc
    if answer.get("ok") is not True:
        raise TelegramError(method,str(answer.get("description") or "API error"))
    return answer.get("result")

def update(project,api=telegram):
    conf=PROJECTS[project]
    token=os.environ.get(conf["bot_token"],"")
    fallback=read("trends/telegram-bot-state.json",{}).get("chat_id") if project=="ttendencias" else None
    chat=os.environ.get(conf["chat"]) or fallback
    if not token or not chat:
        raise RuntimeError("Missing Telegram bot token/chat for "+project)
    chat=str(chat)
    bot=api(token,"getMe",{})
    bot_id=int(bot["id"])
    body,ready,pending=render(project,bot_id)
    signature=hashlib.sha256(body.encode("utf8")).hexdigest()
    st=read(conf["state"],{})
    prev_mid=int(st.get("message_id") or 0)
    mid=prev_mid
    if prev_mid and signature!=st.get("content_sha256"):
        try:
            api(token,"editMessageText",{
                "chat_id":chat,"message_id":prev_mid,
                "text":body,"parse_mode":"HTML",
                "link_preview_options":{"is_disabled":True}})
            print("TT_PINNED_INDEX_EDITED",project,prev_mid,flush=True)
        except TelegramError as exc:
            if "message is not modified" in exc.description.lower():
                pass
            elif ("message to edit not found" in exc.description.lower()
                  or "message_id_invalid" in exc.description.lower()):
                mid=0
            else:raise
    if not mid:
        response=api(token,"sendMessage",{
            "chat_id":chat,"text":body,"parse_mode":"HTML",
            "disable_notification":True,
            "link_preview_options":{"is_disabled":True}})
        mid=int(response["message_id"])
        print("TT_PINNED_INDEX_CREATED",project,mid,flush=True)
    # Enforce a visible pinned header, not only a message in chat history.
    try:
        api(token,"pinChatMessage",{
            "chat_id":chat,"message_id":mid,"disable_notification":True})
        pinned=True
    except TelegramError as exc:
        if "already pinned" in exc.description.lower():pinned=True
        else:
            pinned=False
            print("TT_PINNED_INDEX_PIN_RETRY",project,str(exc),flush=True)
    st.update(version=1,project=project,chat_id=chat,message_id=mid,
              pinned=pinned,bot_id=bot_id,content_sha256=signature,
              ready_count=len(ready),preparing_count=len(pending),
              checked_at=datetime.now(timezone.utc).isoformat())
    write(conf["state"],st)
    print(f"TT_PINNED_INDEX {project} ready={len(ready)} preparing={len(pending)}"
          f" message_id={mid} pinned={pinned}",flush=True)
    if not pinned:
        raise RuntimeError("Telegram did not pin index; will retry")
    return st

def selftest():
    from tempfile import TemporaryDirectory
    global ROOT
    old_root=ROOT
    with TemporaryDirectory() as folder:
        ROOT=Path(folder)
        try:
            write("telegram/lifecycle-baseline.json",{
                "activated_at":"2026-10-12T15:25:23Z",
                "project_state":{"ttendencias":{
                    "historic_max_message_id":719,"preserve_pending_ids":["new-pending"]},
                    "ttittulares":{"historic_max_message_id":3566}}})
            write("trends/telegram-image-deliveries.json",{"items":[
                {"event_id":"historic","title":"Cerrada","telegram_message_id":717,
                 "status":"sent","final":True},
                {"event_id":"ready","title":"Ejemplo explicado","telegram_message_id":722,
                 "status":"sent","final":True},
                {"event_id":"new-pending","title":"Por explicar","telegram_message_id":723,
                 "status":"sent","final":False}]})
            write("trends/editorial-queue.json",{"items":[
                {"id":"new-pending","name":"Por explicar","status":"preparing",
                 "requested_at":"2026-10-12T15:22:26Z"},
                {"id":"missing","name":"Falta aviso","status":"preparing",
                 "requested_at":"2026-10-12T15:40:00Z"},
                {"id":"historic-id","name":"Histórica","status":"preparing",
                 "requested_at":"2026-10-12T14:00:00Z"}]})
            body,ready,pending=render("ttendencias",123456)
            assert body.startswith("LISTAS: 1  |  EN ELABORACIÓN: 2"),body
            assert len(ready)==1 and len(pending)==2
            assert "tg://openmessage?user_id=123456&amp;message_id=722" in body
            assert "message_id=723" not in body
            calls=[]
            def mock(token,method,data):
                calls.append((method,data))
                if method=="getMe":return {"id":123456}
                if method=="sendMessage":return {"message_id":900}
                return True
            os.environ["TTENDENCIAS_BOT_TOKEN"]="fake"
            os.environ["TTENDENCIAS_CHAT_ID"]="1234"
            a=update("ttendencias",mock)
            assert a["message_id"]==900 and a["pinned"]
            assert [x[0] for x in calls]==["getMe","sendMessage","pinChatMessage"]
            calls.clear()
            update("ttendencias",mock)
            assert [x[0] for x in calls]==["getMe","pinChatMessage"]
            deliveries=read("trends/telegram-image-deliveries.json",{})
            deliveries["items"][2]["final"]=True
            write("trends/telegram-image-deliveries.json",deliveries)
            calls.clear()
            update("ttendencias",mock)
            assert [x[0] for x in calls]==["getMe","editMessageText","pinChatMessage"]
            assert calls[1][1]["message_id"]==900
            print("TT_PINNED_INDEX_SELFTEST_OK")
        finally:
            ROOT=old_root

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("project",choices=["ttittulares","ttendencias","selftest"])
    args=p.parse_args()
    if args.project=="selftest":selftest()
    else:update(args.project)
