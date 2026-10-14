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
import subprocess
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from urllib.parse import quote
from pathlib import Path
from urllib.error import HTTPError, URLError
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
    # Long-running Telegram listeners hold a stale checkout for 24-25 min.
    # With REMOTE=1 every input MUST come from one fetched origin/main snapshot.
    if os.getenv("TT_PINNED_INDEX_REMOTE")=="1":
        result=subprocess.run(["git","show","origin/main:"+str(path)],
                              cwd=ROOT,text=True,capture_output=True,timeout=30)
        if result.returncode:
            if path.startswith("telegram/pinned-index-") and "does not exist" in result.stderr:
                return default
            raise RuntimeError("Cannot read LIVE TT index input "+str(path)+": "+
                               result.stderr[:250])
        return json.loads(result.stdout)
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
    closed_ids={str(x.get("event_id") or "") for x in ledger.get("items",[])
        if int(x.get("telegram_message_id") or 0)>watermark
        and str(x.get("status") or "").lower() in {"deleted","removed","delete_pending"}}
    for entry in ledger.get("items",[]):
        mid=int(entry.get("telegram_message_id") or 0)
        if mid<=watermark or str(entry.get("status") or "").lower()!="sent":
            continue
        if not mid:continue
        event_id=str(entry.get("event_id") or "")
        if event_id in closed_ids:continue
        title=shorten(entry.get("title") or entry.get("name") or event_id)
        row={"id":event_id,"title":title,"mid":mid,
             "at":entry.get("delivered_at") or entry.get("updated_at") or ""}
        if entry.get("final") is True:
            final.append(row)
        else:
            pending[event_id]=row
    queue=read(conf["queue"],{"items":[]})
    editorial=list(queue.get("items",[]))
    if project=="ttendencias":
        # Pending requests can survive queue drainage. Never count old,
        # auto-selected Top 11-30 or an already delivered/deleted request.
        for req in read("trends/requests.json",{"requests":[]}).get("requests",[]):
            status=str(req.get("status") or "").lower()
            if status not in {"preparing","update","ready"}:
                continue
            if int(req.get("rank") or 0)>10 and req.get("auto_queued") is True:
                continue
            if (req.get("group_leader_id") and
                    str(req.get("group_leader_id"))!=str(req.get("id"))):
                continue
            editorial.append(req)
    for entry in editorial:
        status=str(entry.get("status") or "").lower()
        if status not in {"preparing","update","processing","ready","in_progress"}:
            continue
        event_id=str(entry.get("id") or entry.get("event_id") or "")
        if not event_id or event_id in closed_ids or event_id in pending or any(x["id"]==event_id for x in final):
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
            if not event_id or event_id in closed_ids or event_id in pending or any(x["id"]==event_id for x in final):
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

def tti_image_launch_status(row):
    """Read only the job ACK. Never infer that ImageGen has finished."""
    event_id=str(row.get("id") or "")
    if not event_id:return "unknown"
    url=("https://raw.githubusercontent.com/fabricelop/europapress-rss/"
         "control/ttittulares-run-trigger-v2/ttittulares/image-runs/jobs/"
         +quote(event_id,safe="")+".json")
    from urllib.request import Request
    import time
    url+="?index_check="+str(int(time.time()))
    req=Request(url,headers={"User-Agent":"TT-private-pinned-index-image-status",
                             "Cache-Control":"no-cache, no-store"})
    try:
        with urlopen(req,timeout=3) as resp:
            job=json.load(resp)
    except HTTPError as exc:
        return "queued" if exc.code==404 else "unknown"
    except (OSError,URLError,TimeoutError,ValueError,TypeError):
        return "unknown"
    # An old revision may have a different generated image.
    if (str(job.get("target_id") or job.get("event_id") or "")!=event_id
        or int(job.get("revision") or 0)!=int(row.get("rev") or 1)):
        return "unknown"
    if job.get("pc_launched_at"):
        return "launched"
    status=str(job.get("status") or "").upper()
    if status in {"ERROR","CANCELLED","SUPERSEDED"}:return "failed"
    if status in {"REQUESTED","RUNNING","PERSISTING"}:return "queued"
    return "unknown"


def tti_image_statuses(rows):
    # Several short independent reads; one unresponsive GitHub request cannot
    # delay the index more than a few seconds. No image generation or download.
    if not rows:return {}
    limited=rows[:30]
    with ThreadPoolExecutor(max_workers=6) as pool:
        result=list(pool.map(tti_image_launch_status,limited))
    return {r["id"]:status for r,status in zip(limited,result)}


def render(project,bot_id,image_statuses=None):
    conf=PROJECTS[project]
    ready,pending=active_records(project)
    first=f"LISTAS: {len(ready)} | EN ELABORACIÓN: {len(pending)}"
    chunks=[first]
    if project=="ttittulares":
        if image_statuses is None:
            # Production uses Telegram's authenticated updater; offline selftests
            # can inject a fixed snapshot without touching the network.
            image_statuses=tti_image_statuses(ready) if os.getenv("TELEGRAM_BOT_TOKEN") else {}
        status_of=lambda r:image_statuses.get(r["id"],"unknown")
        sent=sum(status_of(r)=="launched" for r in ready)
        other=sum(status_of(r)=="unknown" for r in ready)
        chunks.append(f"\n🟢 <b>IA ENVIADA A CHATGPT: {sent} de {len(ready)}</b>")
        if other:chunks.append(f"⚪ Estado no comprobado: {other}")
        chunks.append("<i>Enviada = solicitud confirmada, no imagen terminada.</i>")
        # Only reorder references INSIDE the pinned panel. Original Telegram
        # cards stay where they are, with all existing buttons untouched.
        order={"launched":0,"queued":1,"failed":2,"unknown":3}
        shown=sorted(ready,key=lambda r:(order.get(status_of(r),3),-r["mid"]))
        icons={"launched":"🟢","queued":"🟠","failed":"🔴","unknown":"⚪"}
        labels={"launched":"enviada","queued":"en cola","failed":"falló envío",
                "unknown":"sin verificar"}
        ready_lines=[
            icons[status_of(r)]+" "+html.escape(shorten(r["title"],58))+
            " — "+labels[status_of(r)] for r in shown]
    else:
        ready_lines=["• "+html.escape(shorten(x["title"],65)) for x in ready]
    pending_lines=["• "+html.escape(shorten(x["title"],65)) for x in pending]
    chunks.append("\n<b>LISTAS</b>")
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

def dispatch_delivery_if_missing(project,ready,pending):
    # GitHub's built-in GITHUB_TOKEN commits do not trigger push workflows.
    # The continuous Telegram listener is our independent repair clock.
    if project!="ttendencias" or not os.environ.get("GH_TOKEN"):
        return
    undelivered=[x for x in pending if not int(x.get("mid") or 0)]
    queue=read("trends/editorial-queue.json",{"items":[]})
    finalizable={str(x.get("id") or "") for x in queue.get("items",[])
                 if str(x.get("status") or "").lower() in {"explained","ready"}
                 and bool(x.get("explanation"))}
    provisional=[x for x in pending if x["id"] in finalizable
                 and int(x.get("mid") or 0)>0]
    if not undelivered and not provisional:
        return
    from urllib.request import Request,urlopen
    target=("https://api.github.com/repos/fabricelop/europapress-rss/"
            "actions/workflows/send-ttendencias-explained-telegram.yml/dispatches")
    request=Request(target,data=b'{"ref":"main"}',method="POST",headers={
        "Authorization":"Bearer "+os.environ["GH_TOKEN"],
        "Accept":"application/vnd.github+json",
        "Content-Type":"application/json",
        "User-Agent":"TTendencias-pinned-index-repair"})
    with urlopen(request,timeout=20) as response:
        if response.status!=204:raise RuntimeError("TT delivery dispatch rejected")
    print("TT_PINNED_INDEX_DELIVERY_REPAIR_DISPATCHED",
          "missing="+str(len(undelivered)),
          "ready_to_finalize="+str(len(provisional)),flush=True)


def index_keyboard(project):
    callback="tt:heal" if project=="ttittulares" else "tx:heal"
    text=("Autocorrige "+project+" en fabricelop/europapress-rss. "+
          "Lee telegram/tt-autoheal-state.json, repara colas, envíos e índice, "+
          "verifica Telegram. No borres entradas ni inventes hechos.")
    return {"inline_keyboard":[
        [{"text":"🔧 Autocorregir ahora","callback_data":callback}],
        [{"text":"📋 Orden para ChatGPT","copy_text":{"text":text[:256]}},
         {"text":"Abrir ChatGPT","url":"https://chatgpt.com/"}]
    ]}


def update(project,api=telegram):
    conf=PROJECTS[project]
    if os.getenv("TT_PINNED_INDEX_REMOTE")=="1":
        result=subprocess.run(["git","fetch","origin","main"],cwd=ROOT,
                              text=True,capture_output=True,timeout=45)
        if result.returncode:
            raise RuntimeError("TT_PINNED_INDEX_FETCH_FAILED: "+
                               result.stderr[:400])
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
    keyboard=index_keyboard(project)
    prev_mid=int(st.get("message_id") or 0)
    mid=prev_mid
    applied_keyboard=False
    if prev_mid and signature!=st.get("content_sha256"):
        try:
            api(token,"editMessageText",{
                "chat_id":chat,"message_id":prev_mid,
                "text":body,"parse_mode":"HTML","reply_markup":keyboard,
                "link_preview_options":{"is_disabled":True}})
            applied_keyboard=True
            print("TT_PINNED_INDEX_EDITED",project,prev_mid,flush=True)
        except TelegramError as exc:
            if "message is not modified" in exc.description.lower():
                pass
            elif ("message to edit not found" in exc.description.lower()
                  or "message_id_invalid" in exc.description.lower()):
                raise RuntimeError("Pinned index missing; refuse duplicate index")
            else:raise
    if mid and not applied_keyboard and int(st.get("keyboard_version") or 0)<1:
        api(token,"editMessageReplyMarkup",{
            "chat_id":chat,"message_id":mid,"reply_markup":keyboard})
        applied_keyboard=True
    if not mid:
        response=api(token,"sendMessage",{
            "chat_id":chat,"text":body,"parse_mode":"HTML",
            "reply_markup":keyboard,
            "disable_notification":True,
            "link_preview_options":{"is_disabled":True}})
        mid=int(response["message_id"])
        print("TT_PINNED_INDEX_CREATED",project,mid,flush=True)
    # Enforce a visible pinned header, not only a message in chat history.
    if mid==prev_mid and st.get("pinned") is True:
        pinned=True  # Avoid re-pinning an already confirmed fixed index.
    else:
        try:
            api(token,"pinChatMessage",{
                "chat_id":chat,"message_id":mid,"disable_notification":True})
            pinned=True
        except TelegramError as exc:
            if "already pinned" in exc.description.lower():pinned=True
            else:
                pinned=False
                print("TT_PINNED_INDEX_PIN_RETRY",project,str(exc),flush=True)
    st.update(version=1,keyboard_version=1,project=project,chat_id=chat,message_id=mid,
              pinned=pinned,bot_id=bot_id,content_sha256=signature,
              ready_count=len(ready),preparing_count=len(pending),
              checked_at=datetime.now(timezone.utc).isoformat())
    write(conf["state"],st)
    print(f"TT_PINNED_INDEX {project} ready={len(ready)} preparing={len(pending)}"
          f" message_id={mid} pinned={pinned}",flush=True)
    if not pinned:
        raise RuntimeError("Telegram did not pin index; will retry")
    if os.getenv("TT_PINNED_INDEX_REMOTE")=="1":
        try:
            dispatch_delivery_if_missing(project,ready,pending)
        except Exception as exc:
            print("TT_PINNED_INDEX_DELIVERY_REPAIR_FAILED",project,
                  type(exc).__name__,flush=True)
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
            assert body.startswith("LISTAS: 1 | EN ELABORACIÓN: 2"),body
            assert len(ready)==1 and len(pending)==2
            assert "tg://openmessage" not in body and "message_id=" not in body
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
            assert [x[0] for x in calls]==["getMe"]
            deliveries=read("trends/telegram-image-deliveries.json",{})
            deliveries["items"][2]["final"]=True
            write("trends/telegram-image-deliveries.json",deliveries)
            calls.clear()
            update("ttendencias",mock)
            assert [x[0] for x in calls]==["getMe","editMessageText"]
            assert calls[1][1]["message_id"]==900
            # The TTiTTulares overview must not claim a finished image.
            write("telegram/ttittulares-deliveries.json",{"items":[
                {"event_id":"sent-1","title":"Imagen confirmada","telegram_message_id":3861,
                 "status":"sent","final":True,"revision":1},
                {"event_id":"waiting","title":"En cola","telegram_message_id":3862,
                 "status":"sent","final":True,"revision":1},
                {"event_id":"removed","title":"Ya borrada","telegram_message_id":3863,
                 "status":"deleted","final":True,"revision":1}
            ]})
            write("ttittulares/editorial-queue.json",{"items":[]})
            write("ttittulares/status.json",{"processing_items":[]})
            fixed={"sent-1":"launched","waiting":"queued","removed":"launched"}
            body,ready,pending=render("ttittulares",123456,fixed)
            assert "IA ENVIADA A CHATGPT: 1 de 2" in body
            assert "no imagen terminada" in body
            assert "🟢 Imagen confirmada" in body and "🟠 En cola" in body
            assert body.index("🟢 Imagen confirmada")<body.index("🟠 En cola")
            assert "Ya borrada" not in body
            assert len(ready)==2 and len(pending)==0
            print("TT_PINNED_INDEX_SELFTEST_OK")
        finally:
            ROOT=old_root

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("project",choices=["ttittulares","ttendencias","selftest"])
    args=p.parse_args()
    if args.project=="selftest":selftest()
    else:update(args.project)
