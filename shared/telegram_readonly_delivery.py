#!/usr/bin/env python3
"""PC-independent Telegram delivery: explanation first, or provisional after 60m.

There is NO X or Instagram publishing, and NO AI image generation here.
A final explanation edits the original Telegram card if it has not been deleted.
"""
import argparse
import hashlib
import json
import os
import re
from html.parser import HTMLParser
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import quote
import requests

ROOT=Path(__file__).resolve().parents[1]
TIMEOUT_MINUTES=60
MAX_AGE=timedelta(days=7)  # Only for editing existing provisional cards; new sends <=12h
PHOTO_TIMEOUT=(2.5,3.0)
PHOTO_MAX_BYTES=7_000_000
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

def public_news_detail(item):
    """Keep multinewspaper verification internal; publish the verified facts."""
    explanation=trim(item.get("explanation"),850)
    factual=trim(item.get("factual_summary"),850)
    tweet=trim((item.get("tweet") or {}).get("text"),850)
    # Explanations produced under the old editorial contract sometimes
    # describe the research process instead of explaining the actual event.
    report_about_sources=bool(re.search(
        r"\b(?:Reuters|Associated Press|Europa Press|Cadena SER|"
        r"fuentes?|ambos? medios?|periodicos?|periódicos?|agencias de noticias)\b",
        explanation,re.IGNORECASE
    ))
    return (factual or tweet or explanation) if report_about_sources else (explanation or factual or tweet)

def news_cards(now):
    prepared=load("ttittulares/prepared.json",{"items":[]})
    processing=load("telegram/editorial-processing.json",{"items":[]})
    decisions=load("ttittulares/decisions.json",{"items":[]})
    closed={str(x.get("event_id") or "") for x in decisions.get("items",[])
            if str(x.get("status") or "").lower() in TERMINAL}
    ongoing={}
    for row in processing.get("items",[]):
        key=str(row.get("event_id") or "")
        if key and str(row.get("status") or "").upper() in {"PROCESSING","READY"}:
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
        explanation=public_news_detail(item)
        remate=trim((item.get("tweet") or {}).get("remate"),200)
        if is_final:
            # One good explanation, not a short teaser followed by a second text.
            detail=explanation or factual
            if not detail:detail=trim((item.get("tweet") or {}).get("text"),850)
            if remate and remate in detail:remate=""
            # Telegram photo captions must stay <=1024 chars including the punchline.
            head=title+"\n\n"
            tail="\n\n"+remate if remate else ""
            room=max(0,1000-len(head)-len(tail))
            body=head+detail[:room]+tail
        else:
            pending="⏳ Pendiente de explicación. Se actualizará cuando esté elaborada."
            room=max(0,1000-len(title)-2)
            body=title+"\n\n"+pending[:room]
        # Search is read-only; it never opens a composer.
        search=title
        yield {"id":eid,"rev":revision,"text":body,"image":image_url(item),
               "search":search,"final":is_final,"start":start,"title":title,
               "source_url":str(item.get("url") or job.get("url") or "")}

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
        is_final=bool((finished and str(finished.get("explanation") or "").strip()) or (status=="explained" and str(req.get("explanation") or "").strip()))
        if not is_final and not age_ready(start,now):continue
        label=f"TT#{rank} {name}" if 1<=rank<=30 else name
        detail=trim((finished or {}).get("explanation") or req.get("explanation"),820) if is_final else ""
        closer=trim((finished or {}).get("closer_text"),160)
        if closer and closer not in detail:detail+="\n"+closer
        trend_text=detail if is_final else "⏳ Pendiente de explicación. Se actualizará cuando esté elaborada."
        room=max(0,1000-len(label)-2)
        body=label+"\n\n"+trend_text[:room]
        top_row=top.get(name.casefold()) or {}
        yield {"id":tid,"rev":rev,"text":body,
               "image":image_url(finished or {}) or image_url(req),"search":name,
               "final":is_final,"start":start,"title":name,
               "entered_top_at":top_row.get("entered_top10_at"),
               "novelty_verified":req.get("material_novelty_verified") is True,
               "is_in_top":bool(top_row and 1<=int(top_row.get("rank") or 0)<=10)}

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
            raw,mime,name=photo
            files={"photo":(name,raw,mime)}
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

class _PageImage(HTMLParser):
    def __init__(self):
        super().__init__()
        self.url=""
    def handle_starttag(self,tag,attrs):
        if tag.lower()!="meta":return
        meta={k.lower():v for k,v in attrs if k and v}
        if meta.get("property","").lower() in {"og:image","og:image:url"} or meta.get("name","").lower()=="twitter:image":
            self.url=self.url or meta.get("content","")

def fast_archive_from_article(page):
    # Best-effort, no source research or slow retries.
    if not str(page).startswith("https://"):return ""
    try:
        response=requests.get(page,timeout=(1.5,2.5),headers={"User-Agent":"Mozilla/5.0 TelegramNews/1"},
                              allow_redirects=True,stream=True)
        response.raise_for_status()
        if "text/html" not in response.headers.get("content-type","").lower():return ""
        fragment=b""
        for block in response.iter_content(4096):
            fragment+=block
            if len(fragment)>=80_000:break
        parser=_PageImage()
        parser.feed(fragment.decode("utf-8",errors="ignore"))
        if parser.url:
            from urllib.parse import urljoin
            candidate=urljoin(response.url,parser.url)
            return candidate if candidate.startswith("https://") else ""
    except (requests.RequestException,ValueError):
        pass
    return ""

def archival_image(url):
    if not url or not str(url).startswith("https://"):return None
    try:
        response=requests.get(url,timeout=PHOTO_TIMEOUT,
            headers={"User-Agent":"Mozilla/5.0 TelegramNews/1"},
            stream=True,allow_redirects=True)
        response.raise_for_status()
        typ=response.headers.get("content-type","").lower()
        if not typ.startswith("image/"):return None
        raw=bytearray()
        for block in response.iter_content(64*1024):
            raw.extend(block)
            if len(raw)>PHOTO_MAX_BYTES:return None
        # Telegram sendPhoto can accept JPG/PNG, not SVG/WEBP.
        raw=bytes(raw)
        if raw[:3]==bytes((0xff,0xd8,0xff)):
            return raw,"image/jpeg","archivo.jpg"
        if raw[:8]==bytes((137,80,78,71,13,10,26,10)):
            return raw,"image/png","archivo.png"
    except requests.RequestException:
        pass
    return None

def trend_repeat_allowed(card,history,now):
    # Never resend the same trend for a rank movement or a routine reexplain.
    if card.get("novelty_verified"):return True
    top_at=date(card.get("entered_top_at"))
    if not card.get("is_in_top") or not top_at or now-top_at<timedelta(hours=48):
        return False
    dates=[date(x.get("delivered_at")) for x in history
           if str(x.get("status") or "").lower()=="sent"]
    latest=max((dt for dt in dates if dt is not None),default=None)
    return bool(latest and now-latest>=timedelta(hours=48))

def process(project,now,token,chat):
    path=("telegram/ttittulares-deliveries.json" if project=="ttittulares"
          else "trends/telegram-image-deliveries.json")
    ledger=load(path,{"version":3,"items":[]})
    entries=ledger.setdefault("items",[])
    cards=news_cards(now) if project=="ttittulares" else trend_cards(now)
    delivered=updated=skipped=0
    for card in cards:
        eid=card["id"];rev=card["rev"]
        linked=[r for r in entries if str(r.get("event_id") or "")==eid]
        same_revision=[r for r in linked if int(r.get("revision") or 0)==rev]
        # A Telegram deletion is permanent for this editorial cycle.
        if any(str(r.get("status") or "").lower() in {"deleted","delete_pending","delete_failed"} for r in linked):
            skipped+=1;continue
        # If a provisional message exists, keep editing that same Telegram message,
        # even when ChatGPT saved the explanation under a newer revision.
        existing=next((r for r in reversed(linked)
                       if str(r.get("status") or "").lower()=="sent"
                       and int(r.get("telegram_message_id") or 0)>0
                       and not r.get("final")),None)
        if existing is None and project=="ttittulares":
            # Always update the existing news card, never post a second card
            # just because editorial revisions changed.
            existing=next((r for r in reversed(linked)
                           if str(r.get("status") or "").lower()=="sent"
                           and int(r.get("telegram_message_id") or 0)>0),None)
        if existing is None:
            existing=next((r for r in reversed(same_revision)
                           if str(r.get("status") or "").lower()=="sent"
                           and int(r.get("telegram_message_id") or 0)>0),None)
        if project=="ttendencias" and not existing:
            previous=[r for r in linked if str(r.get("status") or "").lower()=="sent"]
            if previous and not trend_repeat_allowed(card,previous,now):
                skipped+=1;continue
        if project=="ttittulares" and not existing:
            # Headlines are one-time deliveries per event; no duplicates across revisions.
            if any(str(r.get("status") or "").lower()=="sent" for r in linked):
                skipped+=1;continue
        # Never resurrect a deleted item; respect historical terminal decisions.
        if any(str(r.get("status") or "").lower() in TERMINAL for r in same_revision):
            skipped+=1;continue
        # An empty ledger on deployment must NEVER backfill days of history.
        # Existing provisional messages are still editable regardless of age.
        started=date(card.get("start"))
        if existing is None and (not started or now-started>timedelta(hours=12)):
            skipped+=1;continue
        new_hash=hashlib.sha256((card["text"]+"|"+card["image"]).encode("utf-8")).hexdigest()
        kb=keys(card,project)
        image_data=None
        if existing and existing.get("content_sha256")==new_hash and int(existing.get("buttons_version") or 0)==7:
            skipped+=1;continue
        # Try for an archive picture only on the first delivery (or where the
        # existing card is a photo): no separate photo post and no long wait.
        if not existing or existing.get("is_photo"):
            photo_url=card["image"]
            if not photo_url and project=="ttittulares" and not existing:
                photo_url=fast_archive_from_article(card.get("source_url",""))
            image_data=archival_image(photo_url) if photo_url else None
        else:
            photo_url=""
        body=card["text"]
        if existing:
            mid=int(existing["telegram_message_id"])
            old_photo=bool(existing.get("is_photo") or existing.get("image_sha256"))
            if old_photo and image_data:
                # Replace media in the SAME message, not a new photo-plus-text pair.
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
                             "revision":rev,"is_photo":old_photo})
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
                "is_photo":bool(image_data),"image_url":photo_url if image_data else "",
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
    assert not fresh("2026-09-29T12:00:00Z",now)
    card={"id":"abc123","rev":1,"search":"Pedro Sánchez"}
    assert [b[0]["text"] for b in keys(card,"ttittulares")["inline_keyboard"]]==[
        "🔎 Buscar en X","🗑️ Borrar"]
    assert keys(card,"ttendencias")["inline_keyboard"][1][0]["callback_data"]=="tx:b:abc123:1"
    assert not trend_repeat_allowed({"is_in_top":True,"entered_top_at":"2026-10-09T13:00:00Z"},
        [{"status":"sent","delivered_at":"2026-10-09T12:00:00Z"}],now)
    assert trend_repeat_allowed({"is_in_top":True,"entered_top_at":"2026-10-07T00:00:00Z"},
        [{"status":"sent","delivered_at":"2026-10-07T00:00:00Z"}],now)
    assert not trend_repeat_allowed({"is_in_top":False,"entered_top_at":"2026-10-07T00:00:00Z"},
        [{"status":"sent","delivered_at":"2026-10-07T00:00:00Z"}],now)
    assert public_news_detail({"explanation":"Reuters y Associated Press coinciden en la noticia. Ambas fuentes corroboran los datos.","factual_summary":"El comité anunció el premio."})=="El comité anunció el premio."
    assert public_news_detail({"explanation":"La comisión ha aprobado un informe.","factual_summary":"Informe aprobado."})=="La comisión ha aprobado un informe."
    assert archival_image("") is None
    assert "#Actualidad" not in "\n\n".join(x["text"] for x in news_cards(now))
    assert "#Actualidad" not in "\n\n".join(x["text"] for x in trend_cards(now))
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
