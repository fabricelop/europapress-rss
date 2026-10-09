#!/usr/bin/env python3
"""PC-independent Telegram delivery: explanation first, or provisional after 60m.

There is NO X or Instagram publishing, and NO AI image generation here.
A final explanation edits the original Telegram card if it has not been deleted.
"""
import argparse
import hashlib
import json
import os
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import quote
import requests

ROOT=Path(__file__).resolve().parents[1]
TIMEOUT_MINUTES=60
MAX_AGE=timedelta(hours=24)
TERMINAL={"deleted","published","dismissed","removed"}

def load(path,default):
    try:
        return json.loads((ROOT/path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default

def put(path,doc):
    dest=ROOT/path
    dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(json.dumps(doc,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def date(value):
    try:
        out=datetime.fromisoformat(str(value).replace("Z","+00:00"))
        if out.tzinfo is None:out=out.replace(tzinfo=timezone.utc)
        return out.astimezone(timezone.utc)
    except (ValueError,TypeError):
        return None

def age_ready(start,now):
    entered=date(start)
    return bool(entered and now-entered>=timedelta(minutes=TIMEOUT_MINUTES))

def fresh(start,now):
    entered=date(start)
    return bool(entered and -timedelta(minutes=5)<=now-entered<=MAX_AGE)

def image_url(row):
    for key in ("archive_image","fallback_image"):
        obj=row.get(key) or {}
        url=str(obj.get("url") or "").strip() if isinstance(obj,dict) else ""
        if url.startswith("https://") and not obj.get("generated"):
            return url
    return ""

def trim(value,maxlen=900):
    return str(value or "").strip()[:maxlen]

def news_cards(now):
    prepared=load("ttittulares/prepared.json",{"items":[]})
    processing=load("telegram/editorial-processing.json",{"items":[]})
    decisions=load("ttittulares/decisions.json",{"items":[]})
    closed={str(x.get("event_id") or "") for x in decisions.get("items",[])
            if str(x.get("status") or "").lower() in TERMINAL}
    ongoing={}
    for row in processing.get("items",[]):
        key=str(row.get("event_id") or "")
        if key and str(row.get("status") or "").upper() in {"PROCESSING","PROBLEMATIC","READY"}:
            ongoing[key]=row
    ready={str(x.get("event_id") or ""):x for x in prepared.get("items",[])
           if str(x.get("event_id") or "")}
    for eid in set(ongoing)|set(ready):
        if eid in closed:continue
        job=ongoing.get(eid,{})
        item=ready.get(eid,{})
        start=job.get("selected_at") or item.get("selected_at") or item.get("prepared_at")
        if not fresh(start,now):continue
        is_final=bool(item and not item.get("rewrite_pending"))
        if not is_final and not age_ready(start,now):continue
        revision=int(item.get("revision") or job.get("revision") or 1)
        title=trim(item.get("title") or job.get("title") or "Noticia",400)
        factual=trim(item.get("factual_summary") or (item.get("tweet") or {}).get("text"),850)
        explanation=trim(item.get("explanation"),850)
        remate=trim((item.get("tweet") or {}).get("remate"),200)
        if is_final:
            paragraphs=[title]
            if factual and factual.casefold()!=title.casefold():paragraphs.append(factual)
            elif explanation:paragraphs.append(explanation)
            if remate and remate not in factual:paragraphs.append(remate)
            body="\n\n".join(paragraphs)[:1000]
        else:
            body=title+"\n\n⏳ Pendiente de explicación. Se actualizará cuando esté elaborada."
        # Search is read-only; it never opens a composer.
        search=title
        yield {"id":eid,"rev":revision,"text":body,"image":image_url(item),
               "search":search,"final":is_final,"start":start,"title":title}

def trend_cards(now):
    requests_doc=load("trends/requests.json",{"requests":[]})
    manual_doc=load("trends/telegram-manual-explained.json",{"items":[]})
    explained_doc=load("trends/explained.json",{"items":[]})
    recent=load("trends/recent.json",{"items":[]})
    top={str(x.get("name") or "").casefold():x for x in (recent.get("items") or [])[:30]}
    latest={}
    for row in requests_doc.get("requests",[]):
        key=str(row.get("id") or "")
        if key:latest[key]=row
    explained={}
    for row in [*explained_doc.get("items",[]),*manual_doc.get("items",[])]:
        key=str(row.get("id") or "")
        if key and str(row.get("explanation") or "").strip():
            rev=int(row.get("revision") or 0)
            current=explained.get((key,rev))
            if current is None or str(row.get("explained_at") or "")>str(current.get("explained_at") or ""):
                explained[(key,rev)]=row
    for tid,req in latest.items():
        status=str(req.get("status") or "").lower()
        if status not in {"preparing","update","ready","explained"}:continue
        name=trim(req.get("name"),200)
        if not name:continue
        rank=int(req.get("rank") or (top.get(name.casefold()) or {}).get("rank") or 0)
        # Unranked legacy/manual trends and positions 11-30 are opt-in only.
        if rank>10 and req.get("auto_queued") is True:continue
        start=req.get("requested_at") or req.get("anticipated_at")
        if not fresh(start,now):continue
        rev=int(req.get("revision") or 0)
        finished=explained.get((tid,rev))
        is_final=bool(finished and str(finished.get("explanation") or "").strip())
        if not is_final and not age_ready(start,now):continue
        label=f"TT#{rank} {name}" if 1<=rank<=30 else name
        detail=trim((finished or {}).get("explanation") or req.get("explanation"),820) if is_final else ""
        closer=trim((finished or {}).get("closer_text"),160)
        if closer and closer not in detail:detail+="\n"+closer
        body=(label+"\n\n"+(detail if is_final else "⏳ Pendiente de explicación. Se actualizará cuando esté elaborada."))[:1000]
        yield {"id":tid,"rev":rev,"text":body,
               "image":image_url(finished or req),"search":name,
               "final":is_final,"start":start,"title":name}

def keys(card,project):
    callback=("tt:b:"+card["id"]) if project=="ttittulares" else ("tx:b:"+card["id"]+":"+str(card["rev"]))
    return {"inline_keyboard":[
        [{"text":"🔎 Buscar en X","url":"https://x.com/search?q="+quote(card["search"])+"&f=live"}],
        [{"text":"🗑️ Borrar","callback_data":callback}],
    ]}

def send(token,method,payload,photo=None):
    base="https://api.telegram.org/bot"+token+"/"+method
    try:
        if photo is not None:
            files={"photo":("archivo.jpg",photo,"image/jpeg")}
            form={k:(json.dumps(v,ensure_ascii=False) if isinstance(v,(dict,list)) else str(v)) for k,v in payload.items()}
            response=requests.post(base,data=form,files=files,timeout=40)
        else:
            response=requests.post(base,json=payload,timeout=35)
        data=response.json()
        if not response.ok or not data.get("ok"):
            print("TELEGRAM_DELIVERY_RETRY",method,response.status_code,
                  str(data.get("description") or "")[:100],flush=True)
            return None
        return data.get("result") or {}
    except (requests.RequestException,ValueError) as exc:
        print("TELEGRAM_DELIVERY_RETRY",method,type(exc).__name__,flush=True)
        return None

def archival_image(url):
    if not url:return None
    try:
        response=requests.get(url,timeout=18,headers={"User-Agent":"TTreadOnlyTelegram/1.0"})
        response.raise_for_status()
        if not str(response.headers.get("content-type") or "").lower().startswith("image/"):return None
        raw=response.content
        if len(raw)>9_000_000 or len(raw)<1000:return None
        # Sender should avoid sending non-JPEG bytes as JPEG.
        if raw[:3]==b"\\xff\\xd8\\xff":return raw
    except requests.RequestException:
        pass
    return None

def process(project,now,token,chat):
    path=("telegram/ttittulares-deliveries.json" if project=="ttittulares"
          else "trends/telegram-image-deliveries.json")
    ledger=load(path,{"version":3,"items":[]})
    entries=ledger.setdefault("items",[])
    cards=news_cards(now) if project=="ttittulares" else trend_cards(now)
    delivered=updated=skipped=0
    for card in cards:
        eid=card["id"];rev=card["rev"]
        linked=[r for r in entries if str(r.get("event_id") or "")==eid
                and int(r.get("revision") or 0)==rev]
        # Never resurrect a deleted item; respect historical terminal decisions.
        if any(str(r.get("status") or "").lower() in TERMINAL for r in linked):
            skipped+=1;continue
        existing=next((r for r in reversed(linked)
                       if str(r.get("status") or "").lower()=="sent"
                       and int(r.get("telegram_message_id") or 0)>0),None)
        new_hash=hashlib.sha256((card["text"]+"|"+card["image"]).encode("utf-8")).hexdigest()
        kb=keys(card,project)
        image_data=None
        if existing and existing.get("content_sha256")==new_hash and int(existing.get("buttons_version") or 0)==7:
            skipped+=1;continue
        if card["image"]:image_data=archival_image(card["image"])
        body=card["text"]
        if existing:
            mid=int(existing["telegram_message_id"])
            old_photo=bool(existing.get("is_photo") or existing.get("image_sha256"))
            if old_photo and image_data:
                result=send(token,"editMessageMedia",{"chat_id":chat,"message_id":mid,
                    "media":{"type":"photo","media":"attach://photo","caption":body},
                    "reply_markup":kb},image_data)
            elif old_photo:
                result=send(token,"editMessageCaption",{"chat_id":chat,"message_id":mid,
                    "caption":body,"reply_markup":kb})
            else:
                result=send(token,"editMessageText",{"chat_id":chat,"message_id":mid,
                    "text":body,"reply_markup":kb})
            if not result:continue
            existing.update({"content_sha256":new_hash,"final":card["final"],
                             "buttons_version":7,"updated_at":now.isoformat(),
                             "is_photo":old_photo})
            updated+=1
        else:
            # In case old non-photo deliveries exist, do not duplicate them.
            if image_data:
                result=send(token,"sendPhoto",{"chat_id":chat,"caption":body,
                    "reply_markup":kb},image_data)
            else:
                result=send(token,"sendMessage",{"chat_id":chat,"text":body,
                    "reply_markup":kb})
            if not result or not result.get("message_id"):continue
            entries.append({"delivery_key":f"{eid}:r{rev}:readonly",
                "event_id":eid,"revision":rev,"title":card["title"],"name":card["title"],
                "telegram_message_id":int(result["message_id"]),"status":"sent",
                "is_photo":bool(image_data),"image_url":card["image"] if image_data else "",
                "content_sha256":new_hash,"final":card["final"],"buttons_version":7,
                "started_at":str(card["start"]),"delivered_at":now.isoformat()})
            delivered+=1
        ledger["updated_at"]=now.isoformat()
    if delivered or updated:put(path,ledger)
    print(f"TELEGRAM_READONLY {project} delivered={delivered} updated={updated} skipped={skipped}",flush=True)
    return delivered,updated

def selftest():
    now=datetime(2026,10,9,16,0,tzinfo=timezone.utc)
    assert not age_ready("2026-10-09T15:01:00Z",now)
    assert age_ready("2026-10-09T15:00:00Z",now)
    assert not fresh("2026-10-08T12:00:00Z",now)
    card={"id":"abc123","rev":1,"search":"Pedro Sánchez"}
    assert [b[0]["text"] for b in keys(card,"ttittulares")["inline_keyboard"]]==[
        "🔎 Buscar en X","🗑️ Borrar"]
    assert keys(card,"ttendencias")["inline_keyboard"][1][0]["callback_data"]=="tx:b:abc123:1"
    print("TELEGRAM_READONLY_SELFTEST_OK")

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("project",choices=["ttittulares","ttendencias","selftest"])
    args=parser.parse_args()
    if args.project=="selftest":selftest()
    else:
        token=os.environ.get("TELEGRAM_BOT_TOKEN" if args.project=="ttittulares" else "TTENDENCIAS_BOT_TOKEN","")
        chat=os.environ.get("TELEGRAM_CHAT_ID" if args.project=="ttittulares" else "TTENDENCIAS_CHAT_ID","")
        if not chat and args.project=="ttendencias":
            chat=str(load("trends/telegram-bot-state.json",{}).get("chat_id") or "")
        if not token or not chat:raise SystemExit("Telegram credentials/chat missing")
        process(args.project,datetime.now(timezone.utc),token,chat)
