#!/usr/bin/env python3
"""PC-independent Telegram delivery: immediate news provisional and in-place final edits.

There is NO X or Instagram publishing, and NO AI image generation here.
A final explanation edits the original Telegram card if it has not been deleted.
"""
import argparse
import hashlib
import json
import io
import os
import re
import sys
import unicodedata
from html.parser import HTMLParser
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.parse import quote, urlparse, urlencode
import requests

ROOT=Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:sys.path.insert(0,str(ROOT))
TIMEOUT_MINUTES=60
MAX_AGE=timedelta(days=7)  # Existing cards and repairable final Listas entries; provisional first sends stay <=12h
PHOTO_TIMEOUT=(2.5,3.0)
PHOTO_MAX_BYTES=7_000_000
BUTTONS_VERSION=16  # TTendencias: no archive media
TTI_BUTTONS_VERSION=18  # TTiTTulares: no archive media
IMAGE_APP="https://chatgpt.com/images"
TTI_ORIGIN="https://tt-control.fabricelop.workers.dev"
TTEND_ORIGIN="https://tt-control.fabricelop.workers.dev"
TERMINAL={"deleted","published","dismissed","removed","delete_pending","delete_failed"}

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

def ai_delivery_info(item,now):
    """Sólo informar si el prompt fue enviado a ChatGPT Images; nunca recuperar imagen."""
    eid=str(item.get("event_id") or "")
    rev=int(item.get("revision") or 1)
    job={}
    if eid and os.environ.get("TELEGRAM_BOT_TOKEN"):
        try:
            url=("https://raw.githubusercontent.com/fabricelop/europapress-rss/"
                 "control/ttittulares-run-trigger-v2/ttittulares/image-runs/jobs/"
                 +quote(eid,safe="")+".json?at="+str(int(now.timestamp())))
            response=requests.get(url,timeout=(1.0,1.5),headers={"Cache-Control":"no-cache"})
            if response.ok:
                found=response.json()
                if (str(found.get("target_id") or found.get("event_id") or "")==eid
                        and int(found.get("revision") or 0)==rev):
                    job=found
        except (requests.RequestException,ValueError,TypeError,AttributeError):
            pass
    if job.get("pc_launched_at"):
        return {"url":"","note":"🖼️ Enviada a ChatGPT Images."}
    requested=date(job.get("requested_at"))
    status=str(job.get("status") or "").upper()
    if status in {"ERROR","CANCELLED","SUPERSEDED"}:
        return {"url":"","note":"🖼️ Sin imagen IA · fallo de lanzamiento."}
    if status in {"REQUESTED","RUNNING","PERSISTING"}:
        if requested and (now-requested).total_seconds()>=1800:
            return {"url":"","note":"🖼️ En cola · el PC no ha confirmado recepción; se conserva la solicitud."}
        return {"url":"","note":"🖼️ En cola para ChatGPT Images."}
    entered=date(item.get("prepared_at") or item.get("ready_at"))
    if entered and (now-entered).total_seconds()>900:
        return {"url":"","note":"🖼️ Sin imagen IA · no se lanzó."}
    return {"url":"","note":"🖼️ Pendiente de enviar a ChatGPT Images."}


def trend_image_launch_info(tid,revision,now):
    """Estado exclusivo del lanzamiento; la imagen se recoge en ChatGPT Images."""
    job={}
    if tid and os.environ.get("TELEGRAM_BOT_TOKEN"):
        try:
            url=("https://raw.githubusercontent.com/fabricelop/europapress-rss/"
                 "control/ttendencias-run-trigger/trends/image-runs/jobs/"
                 +quote(tid,safe="")+".json?at="+str(int(now.timestamp())))
            response=requests.get(url,timeout=(1.0,1.5),headers={"Cache-Control":"no-cache"})
            if response.ok:
                found=response.json()
                if (str(found.get("target_id") or "")==str(tid)
                        and int(found.get("revision") or 0)==int(revision)):
                    job=found
        except (requests.RequestException,ValueError,TypeError,AttributeError):
            pass
    if job.get("pc_launched_at"):
        return "🖼️ Enviada a ChatGPT Images."
    status=str(job.get("status") or "").upper()
    if status in {"ERROR","CANCELLED","SUPERSEDED"}:
        return "🖼️ Sin imagen IA · fallo de lanzamiento."
    requested=date(job.get("requested_at"))
    if status in {"REQUESTED","RUNNING","PERSISTING"}:
        if requested and (now-requested).total_seconds()>=120:
            return "🖼️ Sin imagen IA · el PC no lanzó la orden."
        return "🖼️ Pendiente de enviar a ChatGPT Images."
    return "🖼️ Pendiente de enviar a ChatGPT Images."

def attach_news_ai(card,entry,token,chat,ledger_path,ledger,now):
    """Entrega como respuesta una única imagen IA; nunca modifica botones ni reenvía noticias."""
    if not entry or str(entry.get("status") or "").lower()!="sent":
        return False
    if int(entry.get("ai_telegram_message_id") or 0)>0:
        return False
    url=str(card.get("ai_url") or "")
    mid=int(entry.get("telegram_message_id") or 0)
    if not url or mid<=0:
        return False
    photo=archival_image(url)
    if not photo:
        return False
    result=send(token,"sendPhoto",{"chat_id":chat,
         "caption":"🖼️ Imagen IA · "+trim(card.get("title"),150),
         "reply_to_message_id":mid},photo)
    if not result or not result.get("message_id"):
        return False
    entry["ai_telegram_message_id"]=int(result["message_id"])
    entry["ai_image_url"]=url
    entry["ai_attached_at"]=now.isoformat()
    entry["updated_at"]=now.isoformat()
    ledger["updated_at"]=now.isoformat()
    put(ledger_path,ledger)  # Guardar ID antes de editar: reintento idempotente.
    return True


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

def news_delivery_start(job,item):
    """Final news ages from entering Listas; provisional news ages from selection.

    A long editorial investigation must not make an otherwise fresh READY card
    silently ineligible for Telegram's first-delivery window.
    """
    if item and not item.get("rewrite_pending"):
        return item.get("prepared_at") or item.get("ready_at") or item.get("selected_at") or job.get("selected_at")
    return job.get("selected_at") or item.get("selected_at") or item.get("prepared_at")

def provisional_news_copy(job,title):
    """Clearly labeled early draft for manual X posting, never a verified fact."""
    try:verified=int(job.get("verified_source_count") or 0)>=2
    except (ValueError,TypeError):verified=False
    draft=trim(job.get("factual_summary"),210) if verified else ""
    lead="🔎 EN ELABORACIÓN (aún sin explicación): " if verified and draft else "⚠️ TITULAR EN VERIFICACIÓN: "
    body=draft or trim(title,210)
    limit=250-len(lead)
    if len(body)>limit:
        body=body[:limit].rsplit(" ",1)[0].rstrip(".,;: ")+"…"
    return lead+body

GENERIC_NEWS_TITLES={"noticia","sin título","sin titulo","actualidad","titular pendiente",""}
def authentic_news_title(value):
    title=trim(value,400)
    return title if title.casefold().strip(" .:–-") not in GENERIC_NEWS_TITLES else ""

def recover_news_metadata(eid,*rows):
    """Recover capture metadata by ID; never invent a headline or source."""
    candidates=[row for row in rows if isinstance(row,dict)]
    for filename,fields in (
        ("telegram/events.json",("events",)),
        ("ttittulares/editorial-queue.json",("items",)),
        ("ttittulares/status.json",("processing_items","ready_items","items")),
        ("ttittulares/prepared.json",("items",)),
    ):
        document=load(filename,{})
        for field in fields:
            candidates.extend(row for row in (document.get(field) or [])
                              if isinstance(row,dict) and
                              str(row.get("event_id") or row.get("id") or "")==eid)
    title=next((t for row in candidates
                if (t:=authentic_news_title(row.get("canonical_title") or row.get("title")))), "")
    url=next((str(row.get("url") or "") for row in candidates
              if str(row.get("url") or "").startswith("https://")), "")
    appearance=next((a for row in candidates for a in (row.get("appearances") or [])
                     if isinstance(a,dict) and a.get("source")
                     and str(a.get("url") or "").startswith("https://")), {})
    if not url:url=str(appearance.get("url") or "")
    source=next((str(a.get("source")) for row in candidates for a in (row.get("appearances") or [])
                 if isinstance(a,dict) and str(a.get("url") or "")==url and a.get("source")), "")
    if not source:source=next((str(row.get("source") or "") for row in candidates if row.get("source")), "")
    if not source:source=str(appearance.get("source") or "")
    if not source:
        source=next((str(row.get("sources")[0]) for row in candidates
                     if isinstance(row.get("sources"),list) and row["sources"]), "")
    image=next((image_url(row) for row in candidates if image_url(row)), "")
    return title,url,source,image

def lifecycle_baseline():
    """Confirmed empty Telegram chats: archive prior deliveries, not editorial history.

    Both Telegram Actions jobs use sparse-checkout. Read the committed
    checkpoint directly from the git tree when not mounted locally.
    """
    local=load("telegram/lifecycle-baseline.json",None)
    if isinstance(local,dict):return local
    if ROOT!=Path(__file__).resolve().parents[1]:return {}
    try:
        import subprocess
        result=subprocess.run(
            ["git","show","origin/main:telegram/lifecycle-baseline.json"],
            cwd=str(ROOT),capture_output=True,text=True,timeout=8,check=True)
        return json.loads(result.stdout)
    except (OSError,ValueError,subprocess.SubprocessError):
        print("TT_LIFECYCLE_BASELINE_NOT_READABLE",flush=True)
        return {}

def baseline_details(project):
    doc=lifecycle_baseline()
    project_state=(doc.get("project_state") or {}).get(project) or {}
    cut=date(doc.get("activated_at"))
    return cut,int(project_state.get("historic_max_message_id") or 0),{
        str(x) for x in (project_state.get("preserve_pending_ids") or [])}

def baseline_allows(project,eid,start):
    cut,_,keep=baseline_details(project)
    if cut is None or str(eid) in keep:return True
    moment=date(start)
    # Unknown/undated old material MUST NOT repopulate an empty chat.
    return bool(moment and moment>cut)

def active_delivery_rows(project,entries):
    cut,watermark,_=baseline_details(project)
    if cut is None:return entries
    # Message IDs are monotonic per Telegram chat: old ledger records remain
    # historic, but are NOT live messages and cannot close new entries.
    return [row for row in entries
            if int(row.get("telegram_message_id") or 0)>watermark]

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
        is_final=bool(item and not item.get("rewrite_pending"))
        start=news_delivery_start(job,item)
        if not fresh(start,now) or not baseline_allows("ttittulares",eid,start):
            continue
        # New PROCESSING news is sent immediately, with an explicit warning.
        revision=int(item.get("revision") or job.get("revision") or 1)
        title,original_url,original_source,original_image=recover_news_metadata(eid,item,job)
        if not title:
            print("TTI_MISSING_AUTHENTIC_TITLE",eid,"delivery blocked; retry next run",flush=True)
            continue
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
            room=max(0,900-len(head)-len(tail))
            body=head+detail[:room]+tail
        else:
            # En Elaboración: únicamente el aviso y el titular auténtico.
            # Ni fuentes, enlaces, avances, avisos extra ni estado de imágenes.
            # El mismo mensaje se completará en Listas, conservando sus botones.
            body="🟠 EN ELABORACIÓN\n\n"+trim(title,400)
        ai_info=ai_delivery_info(item,now) if is_final else {"url":"","note":""}
        # Search is read-only; it never opens a composer.
        search=title
        yield {"id":eid,"rev":revision,"text":body,"x_text":(item.get("tweet") or {}).get("text") if is_final else provisional_news_copy(job,title),
               "image":original_image if is_final else "",
               "search":search,"final":is_final,"start":start,"title":title,
               "source_url":original_url,"source":original_source,
               "ai_url":ai_info["url"],"ai_note":ai_info["note"]}

def verified_article_urls(*rows):
    """Prefer a checked news article, not a homepage or a generated image."""
    urls=[]
    for row in rows:
        if not isinstance(row,dict):continue
        for field in ("verification_sources","source_articles","news_sources","references"):
            for entry in row.get(field) or []:
                url=(entry.get("url") or entry.get("source_url") or "") if isinstance(entry,dict) else entry
                if isinstance(url,str) and url.startswith("https://") and url not in urls:
                    parsed=urlparse(url)
                    if len([part for part in parsed.path.split("/") if part])>=2:
                        urls.append(url)
        for field in ("fallback_image","archive_image"):
            item=row.get(field)
            url=item.get("source_url") if isinstance(item,dict) else ""
            if isinstance(url,str) and url.startswith("https://") and url not in urls:
                urls.append(url)
    # Use an official event homepage as a last resort when article metadata
    # is incomplete; it may carry the event's genuine photograph/poster.
    for row in rows:
        if not isinstance(row,dict):continue
        for entry in row.get("verification_sources") or []:
            url=(entry.get("url") or "") if isinstance(entry,dict) else entry
            if isinstance(url,str) and url.startswith("https://") and url not in urls:
                parsed=urlparse(url)
                if len([part for part in parsed.path.split("/") if part])>=1:
                    urls.append(url)
    return urls[:3]

def trend_body(label,detail,is_final):
    if not is_final:
        return label+"\n\n⏳ Pendiente de explicación. Se actualizará cuando esté elaborada."
    # The editorial explanation already starts with "TT#14 #Sitges2026...".
    # Do not prepend a second identical title.
    detail=trim(detail,950)
    if re.match(r"^TT#\d+\b",detail,re.IGNORECASE):
        return detail
    return (label+"\n\n"+detail)[:1000]

def trend_cards(now):
    """One Telegram card per verified editorial event, not per related term.

    Shared photographs or a common batch are NOT sufficient to group stories.
    Only a persisted editorial group_leader_id/explanation_group_id can merge
    members. Each term still has its own Top 30 rank and request status.
    """
    requests_doc=load("trends/requests.json",{"requests":[]})
    manual_doc=load("trends/telegram-manual-explained.json",{"items":[]})
    explained_doc=load("trends/explained.json",{"items":[]})
    recent=load("trends/recent.json",{"items":[]})
    top={str(x.get("name") or "").casefold():x for x in (recent.get("items") or [])[:30]}
    existing_sent_ids={str(x.get("event_id") or "")
        for x in load("trends/telegram-image-deliveries.json",{"items":[]}).get("items",[])
        if str(x.get("status") or "").lower()=="sent" and
           int(x.get("telegram_message_id") or 0)>0}
    latest={}
    for row in requests_doc.get("requests",[]):
        key=str(row.get("id") or "")
        if key:latest[key]=row
    # The radar/editor queue can advance before the massive requests.json is
    # persisted. Read the queue itself so a Top 10 trend cannot remain
    # "pendiente de Telegram" indefinitely. Existing Telegram deletions are
    # still enforced by process() against the authoritative delivery ledger.
    editorial_queue=load("trends/editorial-queue.json",{"items":[]})
    for queued in editorial_queue.get("items",[]):
        tid=str(queued.get("id") or "")
        if not tid or str(queued.get("status") or "").lower() not in {
                "preparing","update","ready","explained"}:
            continue
        prior=latest.get(tid)
        if prior is None:
            latest[tid]=dict(queued)
        elif int(prior.get("revision") or 0)==int(queued.get("revision") or 0):
            # Keep the request's durable metadata, but reflect freshly
            # verified editorial text if it was committed in the queue.
            if queued.get("editorial_verified") is True and queued.get("explanation"):
                latest[tid]={**prior,**queued}
            elif str(prior.get("status") or "").lower() not in {
                    "deleted","dismissed","published","removed"}:
                # The active editorial queue is newer than an already
                # explained old request ONLY if its requested_at follows the
                # previous explanation; this must not resurrect user deletes.
                new_at=date(queued.get("requested_at"))
                final_at=date(prior.get("explained_at"))
                if not final_at or (new_at and new_at>=final_at):
                    latest[tid]={**prior,**queued}
                    latest[tid]["status"]=queued["status"]
                    latest[tid]["revision"]=int(queued.get("revision") or 0)
                    # Old re-explanation flags must not indefinitely suppress
                    # a fresh automatically selected Top 10 provisional.
                    if queued.get("reexplain") is False:
                        latest[tid]["reexplain"]=False
    explained={}
    for row in [*explained_doc.get("items",[]),*manual_doc.get("items",[])]:
        key=str(row.get("id") or "")
        if key and str(row.get("explanation") or "").strip():
            rev=int(row.get("revision") or 0)
            current=explained.get((key,rev))
            if current is None or str(row.get("explained_at") or "")>str(current.get("explained_at") or ""):
                explained[(key,rev)]=row

    groups={}
    for tid,req in latest.items():
        leader=str(req.get("group_leader_id") or "").strip()
        group_id=str(req.get("explanation_group_id") or req.get("group_id") or "").strip()
        if leader and group_id:
            group=groups.setdefault(leader,{"group_id":group_id,"members":{}})
            if group["group_id"]==group_id:
                group["members"][tid]=req
    # Also respect group membership persisted in the only explanation row
    # when the per-request metadata was not synchronized yet.
    for row in manual_doc.get("items",[]):
        leader=str(row.get("group_leader_id") or row.get("id") or "").strip()
        gid=str(row.get("explanation_group_id") or row.get("group_id") or "").strip()
        if not leader or not gid or not row.get("grouped_member_revisions"):
            continue
        group=groups.setdefault(leader,{"group_id":gid,"members":{}})
        if group["group_id"]!=gid:
            continue
        for member in row["grouped_member_revisions"]:
            if isinstance(member,dict):
                mid=str(member.get("id") or "")
                if mid in latest: group["members"][mid]=latest[mid]

    for tid,req in latest.items():
        status=str(req.get("status") or "").lower()
        if status not in {"preparing","update","ready","explained"}:continue
        name=trim(req.get("name"),200)
        if not name:continue
        group_leader=str(req.get("group_leader_id") or "").strip()
        group_id=str(req.get("explanation_group_id") or req.get("group_id") or "").strip()
        # Preserve an explicitly open pending card across the checkpoint.
        # Old grouped followers remain deduplicated, but a new/open card
        # must be visible independently until its OWN Telegram delete.
        _,_,protected=baseline_details("ttendencias")
        if group_id and group_leader and group_leader!=tid and tid not in protected:
            continue

        # An old request may retain rank 11-30 after re-entering the Top 10.
        # Current captured rank wins over stale request rank for delivery.
        rank=int((top.get(name.casefold()) or {}).get("rank") or req.get("rank") or 0)
        if rank>10 and req.get("auto_queued") is True:
            if any(str(x.get("id") or "")==tid for x in editorial_queue.get("items",[])):
                print("TT_TREND_PENDING_DIAG",tid,"outside_top10",rank,flush=True)
            continue
        start=req.get("requested_at") or req.get("anticipated_at")
        if not fresh(start,now) or not baseline_allows("ttendencias",tid,start):
            if any(str(x.get("id") or "")==tid for x in editorial_queue.get("items",[])):
                print("TT_TREND_PENDING_DIAG",tid,"stale_or_baseline",str(start),flush=True)
            continue
        rev=int(req.get("revision") or 0)
        finished=explained.get((tid,rev))
        is_final=bool((finished and str(finished.get("explanation") or "").strip())
                      or (status=="explained" and str(req.get("explanation") or "").strip()))
        queued_current=next((x for x in editorial_queue.get("items",[])
                            if str(x.get("id") or "")==tid and
                               int(x.get("revision") or 0)==rev and
                               str(x.get("status") or "").lower() in {"preparing","update","ready"}),None)
        if req.get("reexplain") and not is_final and tid in existing_sent_ids:
            if queued_current:
                print("TT_TREND_PENDING_DIAG",tid,"reexplain_existing_card_pending",rev,flush=True)
            continue
        # An automatically queued TOP 10 item with reexplain=True may never
        # have received any Telegram card. It still needs its first provisional.
        # Provisional notices for newly pending TTendencias go out immediately.
        # Unlike TTiTTulares, there is no one-hour delay. A later final card
        # edits the ORIGINAL Telegram message (preserving its message_id).
        current_rank=int((top.get(name.casefold()) or {}).get("rank") or 0)
        manual_request=(req.get("auto_queued") is False and
                        str(req.get("request_source") or "") in {
                            "github_pages_authorized_issue",
                            "telegram_private_deeplink_native",
                            "telegram_reexplain"})
        if not is_final and not (1<=current_rank<=10 or manual_request or tid in protected):
            if any(str(x.get("id") or "")==tid for x in editorial_queue.get("items",[])):
                print("TT_TREND_PENDING_DIAG",tid,"current_rank_not_eligible",current_rank,flush=True)
            continue
        label=f"TT#{rank} {name}" if 1<=rank<=30 else name
        detail=trim((finished or {}).get("explanation") or req.get("explanation"),820) if is_final else ""
        closer=trim((finished or {}).get("closer_text") or req.get("closer_text"),160)
        if closer and closer not in detail:detail+="\n"+closer
        group=groups.get(tid) if group_id else None
        member_ids=[]
        group_title=""
        if group and len(group["members"])>1:
            members=sorted(group["members"].items(), key=lambda pair:(
                int((top.get(str(pair[1].get("name") or "").casefold()) or {}).get("rank")
                    or pair[1].get("rank") or 999),
                str(pair[1].get("name") or "")))
            member_ids=[mid for mid,_ in members]
            terms=[]
            for mid,member in members:
                term=trim(member.get("name"),100)
                number=int((top.get(term.casefold()) or {}).get("rank")
                           or member.get("rank") or 0)
                terms.append(f"TT#{number} {term}" if 1<=number<=30 else term)
            # Keep the editorial paragraph and ONE punchline intact.
            # Header makes visible that the explanation covers all trends.
            group_title=" · ".join(terms)
            if is_final:
                # The leading historic rank belongs to the leader and may
                # already have changed. Show the current rank for EVERY term
                # in the joint header, then ONE untouched factual paragraph.
                match=re.match(r"^TT#\d+\s+(.+?)\s+es tendencia por(?:que)?\s+",
                               detail, flags=re.I)
                if match:
                    group_detail=("Todas se relacionan con el mismo acontecimiento: "+
                                  match.group(1)+" "+detail[match.end():])
                else:
                    group_detail=re.sub(r"^TT#\d+\s+", "", detail, count=1, flags=re.I)
                body=group_title+"\n\n"+group_detail
                # A single joint copy, never the same separate tweet repeated
                # four times. A long joint caption uses the full-copy page.
                x_text=body
            else:
                body=group_title+"\n\n⏳ Pendiente de explicación. Se actualizará cuando esté elaborada."
                x_text=""
            body=trim(body,1000)
        else:
            body=trend_body(label,detail,is_final)
            x_text=detail if is_final else ""
        sources=verified_article_urls(finished or {},req)
        top_row=top.get(name.casefold()) or {}
        yield {"id":tid,"rev":rev,"text":body,"x_text":x_text,
               "image":image_url(finished or {}) or image_url(req),
               "archive_articles":sources,
               "search":(" ".join(str(g["name"]) for g in group["members"].values())
                         if member_ids else name),
               "final":is_final,"start":start,
               "title":group_title or name,"group_id":group["group_id"] if member_ids else "",
               "group_member_ids":member_ids,
               "editorial_rework":bool(req.get("reexplain") or req.get("request_source")=="telegram_reexplain"),
               "entered_top_at":top_row.get("entered_top10_at"),
               "novelty_verified":req.get("material_novelty_verified") is True,
               "is_in_top":bool(top_row and 1<=int(top_row.get("rank") or 0)<=10),
               "ai_note":trend_image_launch_info(tid,rev,now) if is_final else ""}

def mobile_gag_prompt(card,project):
    """Telegram-native copy_text <=256 chars; never relies on a web browser."""
    title=str(card.get("title") or "").strip()
    editorial=str(card.get("x_text") or "").strip()
    lines=[x.strip() for x in editorial.splitlines() if x.strip()]
    punch=next((x for x in reversed(lines) if x.startswith("🌶")), "")
    # When there is no explicit pepper, use only verified title/context.
    lead="Genera UNA imagen GAG IA original: viñeta satírica exagerada, un gag visual ingenioso, sin texto. "
    label="Noticia: " if project=="ttittulares" else "Tendencia: "
    ending=(" Remate exacto: "+punch) if punch else ""
    # Preserve the remate; shorten only the news title when needed.
    if len(lead)+len(label)+len(ending)>248:
        # Exceptional extremely long remate: respect Telegram's native-copy limit.
        ending=ending[:max(0,248-len(lead)-len(label)-12)].rstrip()
    room=max(0,248-len(lead)-len(label)-len(ending))
    short_title=title if len(title)<=room else (title[:max(0,room-1)].rsplit(" ",1)[0].rstrip()+"…" if room>5 else "")
    return (lead+label+short_title+ending).strip()[:248]


def keys(card,project):
    callback=("tt:b:"+card["id"]) if project=="ttittulares" else ("tx:b:"+card["id"]+":"+str(card["rev"]))
    search="https://x.com/search?q="+quote(str(card["search"]))+"&f=live"
    rows=[]
    x_text=str(card.get("x_text") or "").strip()
    if card.get("final") and x_text:
        args={"app":project,"id":str(card["id"]),"rev":str(card["rev"])}
        if project=="ttendencias":args["name"]=str(card.get("title") or "")[:100]
        # Github Pages works on iPhone even when workers.dev is unreachable.
        bridge="https://fabricelop.github.io/europapress-rss/gag.html?"+urlencode(args)
        rows.append([
            {"text":"📄 GAG completo (copiar)","url":bridge},
            {"text":"🎨 Chat Images","url":IMAGE_APP}
        ])
        # Telegram's copy_text is limited to 256 characters. Never truncate
        # editorial text: longer explanations open the full-text copy page.
        if len(x_text)<=256:
            copy_x={"text":"📋 Copiar en X","copy_text":{"text":x_text}}
        else:
            copy_x={"text":"📋 Copiar en X","url":bridge+"&mode=x"}
        rows.append([
            copy_x,
            {"text":"↗ Abrir en X","url":"https://twitter.com/intent/tweet?text="+quote(x_text,safe="")}
        ])
        rows.append([{"text":"🔎 Buscar en X","url":search}])
    elif project=="ttittulares" and x_text:
        # Provisional does not mean unusable: copy/compose X is available
        # immediately, with a visible verification warning in the draft.
        args={"app":project,"id":str(card["id"]),"rev":str(card["rev"])}
        bridge="https://fabricelop.github.io/europapress-rss/gag.html?"+urlencode(args)
        rows.append([
            {"text":"📄 GAG completo (copiar)","url":bridge},
            {"text":"🎨 Chat Images","url":IMAGE_APP}
        ])
        rows.append([
            {"text":"📋 Copiar borrador para X","copy_text":{"text":x_text[:256]}},
            {"text":"↗ Abrir en X","url":"https://twitter.com/intent/tweet?text="+quote(x_text,safe="")}
        ])
        rows.append([{"text":"🔎 Buscar en X","url":search}])
        source_url=str(card.get("source_url") or "")
        if source_url.startswith("https://"):
            rows.append([{"text":"🔗 Fuente original","url":source_url}])
    else:
        rows.append([{"text":"🔎 Buscar en X","url":search}])
    if project=="ttendencias" and card.get("final"):
        rows.append([{"text":"↻ Reexplicar / actualizar","callback_data":"tx:r:"+card["id"]+":"+str(card["rev"])}])
    rows.append([{"text":"🗑️ Borrar","callback_data":callback}])
    return {"inline_keyboard":rows}

def send(token,method,payload,photo=None):
    # Original editorial cards and archive replies remain visible but silent.
    # No green-image alerts: the user chose no Telegram notifications.
    # The image status remains visible in each card and the pinned index.
    if method in {"sendMessage","sendPhoto"}:
        payload={**payload,"disable_notification":True}
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
            description=str(data.get("description") or "")
            print("TELEGRAM_DELIVERY_RETRY",method,response.status_code,
                  description[:100],flush=True)
            if (response.status_code==400 and
                    "message to edit not found" in description.casefold() and
                    method in {"editMessageText","editMessageCaption","editMessageMedia","editMessageReplyMarkup"}):
                return {"_telegram_message_gone":True}
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
        # Telegram sendPhoto accepts JPEG/PNG. Convert news-site WEBP and
        # overly large formats locally; never create synthetic/AI content.
        raw=bytes(raw)
        if raw[:3]==bytes((0xff,0xd8,0xff)):
            return raw,"image/jpeg","archivo.jpg"
        if raw[:8]==bytes((137,80,78,71,13,10,26,10)):
            return raw,"image/png","archivo.png"
        if typ.startswith(("image/webp","image/gif","image/avif","image/bmp")):
            try:
                from PIL import Image, ImageOps
                picture=ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("RGB")
                picture.thumbnail((1800,1800))
                out=io.BytesIO()
                picture.save(out,format="JPEG",quality=86,optimize=True)
                if out.tell()<PHOTO_MAX_BYTES:
                    return out.getvalue(),"image/jpeg","archivo.jpg"
            except (OSError,ValueError,ImportError):
                return None
    except requests.RequestException:
        pass
    return None

def trend_title_key(value):
    normalized=unicodedata.normalize("NFKD",str(value or "").casefold())
    return re.sub(r"[^\w#]+","", "".join(
        char for char in normalized if not unicodedata.combining(char)
    ))

def article_identity(url):
    parsed=urlparse(str(url or "").strip())
    host=(parsed.hostname or "").casefold().removeprefix("www.")
    path=parsed.path.rstrip("/").casefold()
    return host+path if host and path else ""

def matching_previous_story(card,history,now,days=7):
    """Idempotence by actual story, including deletion and publication tombstones."""
    title=trend_title_key(card.get("title"))
    article=article_identity(card.get("source_url"))
    if not title and not article:return None
    eid=str(card.get("id") or "")
    is_news=bool(card.get("source_url"))
    def words(value):
        value=unicodedata.normalize("NFKD",str(value or "").casefold())
        value="".join(c for c in value if not unicodedata.combining(c))
        return {w for w in re.findall(r"[a-z0-9]{4,}",value)
                if w not in {"para","como","sobre","entre","desde","esta","este","tras","ante","hasta","segun"}}
    subject_words=words(card.get("title")) if is_news else set()
    matches=[]
    for row in history:
        if str(row.get("event_id") or "")==eid:continue
        old_title=row.get("title") or row.get("name")
        title_match=bool(title and trend_title_key(old_title)==title)
        article_match=bool(article and article_identity(row.get("source_url"))==article)
        similar=False
        if is_news and not title_match and not article_match and len(subject_words)>=6:
            prior_words=words(old_title)
            common=len(subject_words & prior_words)
            similar=bool(len(prior_words)>=6 and common>=6 and
                         common/max(len(subject_words),len(prior_words))>=0.84)
        if not (title_match or article_match or similar):continue
        when=(date(row.get("delivered_at")) or date(row.get("deleted_at"))
              or date(row.get("published_at")) or date(row.get("dismissed_at")))
        if when is not None and -timedelta(minutes=5)<=now-when<timedelta(days=days):
            matches.append(row)
    # The user decision wins even if another 'sent' card preceded it.
    return next((r for r in matches if str(r.get("status") or "").lower() in TERMINAL),
                None) or (matches[0] if matches else None)


def recently_delivered_same_title(card,history,now,days=7):
    return matching_previous_story(card,history,now,days) is not None

def trend_repeat_allowed(card,history,now):
    # Never auto-repost a routine revision. Only a verified genuinely new
    # development after seven days may justify a new Telegram card.
    if not card.get("novelty_verified"):return False
    top_at=date(card.get("entered_top_at"))
    if not card.get("is_in_top") or not top_at or now-top_at<timedelta(days=7):
        return False
    dates=[date(x.get("delivered_at")) for x in history
           if str(x.get("status") or "").lower()=="sent"]
    latest=max((dt for dt in dates if dt is not None),default=None)
    return bool(latest and now-latest>=timedelta(days=7))


def finalize_existing_group_message(entry,card,body,leader_id,now,token,chat):
    """Finish this user's OWN Telegram card. Never delete or replace its ID."""
    message_id=int(entry.get("telegram_message_id") or 0)
    if not message_id or str(entry.get("status") or "").lower()!="sent":
        return False
    body=trim(body,1000)
    if not body.strip():
        return False
    same_hash=hashlib.sha256((body+"|"+str(entry.get("image_url") or "")).encode("utf-8")).hexdigest()
    if entry.get("final") is True and str(entry.get("grouped_into") or "")==str(leader_id):
        # A previously finalised sibling remains the user's OWN card. Do not
        # fan out later group revisions to every sibling (triple Telegram copy).
        return False
    if entry.get("final") is True and entry.get("content_sha256")==same_hash:
        return False
    group_card={**card,"id":str(entry.get("event_id") or ""),
                "rev":int(entry.get("revision") or 0),
                "image":str(entry.get("image_url") or ""),
                "final":True,"x_text":body,
                "search":str(entry.get("title") or entry.get("name") or card.get("title") or "")}
    method="editMessageCaption" if entry.get("is_photo") else "editMessageText"
    key="caption" if entry.get("is_photo") else "text"
    result=send(token,method,{"chat_id":chat,"message_id":message_id,
               key:body,"reply_markup":keys(group_card,"ttendencias")})
    if not result:
        print("TT_GROUP_FINAL_EDIT_RETRY",group_card["id"],message_id,flush=True)
        return False
    entry.update(status="sent",final=True,content_sha256=same_hash,
                 grouped_into=leader_id,group_leader_id=leader_id,
                 updated_at=now.isoformat())
    print("TT_GROUP_FINAL_EDIT_OK",group_card["id"],message_id,flush=True)
    return True

def process(project,now,token,chat):
    path=("telegram/ttittulares-deliveries.json" if project=="ttittulares"
          else "trends/telegram-image-deliveries.json")
    ledger=load(path,{"version":3,"items":[]})
    treated_refs=[]
    if project=="ttittulares":
        from ttittulares.treated_news import references as treated_references, previous_story
        treated_refs=list(treated_references(
            deliveries=ledger,
            treated=load("ttittulares/treated-stories.json",{"items":[]}),
            decisions=load("ttittulares/decisions.json",{"items":[]})))
    entries=ledger.setdefault("items",[])
    # Only post-checkpoint telegram messages count as active. The old
    # transcript is preserved for history, never re-sent or re-edited.
    active_entries=active_delivery_rows(project,entries)
    cards=list(news_cards(now) if project=="ttittulares" else trend_cards(now))
    delivered=updated=skipped=0
    for card in cards:
        eid=card["id"];rev=card["rev"]
        linked=[r for r in active_entries if str(r.get("event_id") or "")==eid]
        # Si ya existe un mensaje de OTRO ID sobre el mismo hecho, no
        # enviar una segunda tarjeta. Conservar y finalizar cualquier
        # tarjeta propia preexistente; no borrar mensajes automáticamente.
        older=matching_previous_story(card,active_entries,now)
        if older and project=="ttendencias":
            own_provisional=next((r for r in linked
                if str(r.get("status") or "").lower()=="sent" and
                r.get("final") is False and
                int(r.get("telegram_message_id") or 0)>0),None)
            if card.get("final") and own_provisional is not None:
                print("TT_DUPLICATE_FINISH_EXISTING_PROVISIONAL",project,eid,
                      "message_id="+str(own_provisional["telegram_message_id"]),flush=True)
            else:
                print("TT_STORY_DUPLICATE_AWAIT_EDITORIAL",project,
                      trim(card.get("title"),120),"new_id="+str(eid),
                      "previous_id="+str(older.get("event_id") or ""),flush=True)
                skipped+=1
                continue
        elif older and project=="ttittulares" and not linked:
            print("TTI_STORY_DUPLICATE_BLOCKED",eid,
                  "previous_id="+str(older.get("event_id") or ""),
                  "reason=prior-delivery",flush=True)
            skipped+=1
            continue
        same_revision=[r for r in linked if int(r.get("revision") or 0)==rev]
        # A terminal row only closes the revision it belongs to. This matters
        # for TTiTTulares manual reopens: an older revision may have been
        # deleted automatically after a transport_write_blocked fallback, and
        # that cleanup must not suppress a later explicit revision. Real user
        # closures remain protected by decisions.json before cards are built.
        if any(str(r.get("status") or "").lower() in TERMINAL|{"delete_pending","delete_failed"} for r in same_revision):
            print("TT_STORY_CLOSED_BLOCKED",project,trim(card.get("title"),120),
                  "event_id="+str(eid),"revision="+str(rev),flush=True)
            skipped+=1;continue
        # If a provisional message exists, keep editing that same Telegram message,
        # even when ChatGPT saved the explanation under a newer revision.
        existing=next((r for r in reversed(linked)
                       if str(r.get("status") or "").lower()=="sent"
                       and int(r.get("telegram_message_id") or 0)>0
                       and not r.get("final")),None)
        if existing is None and project=="ttendencias" and card.get("editorial_rework") and card.get("final"):
            # For an explicit user re-explanation, update the same Telegram card.
            existing=next((r for r in reversed(linked)
                           if str(r.get("status") or "").lower()=="sent"
                           and int(r.get("telegram_message_id") or 0)>0),None)
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
        if project=="ttittulares" and existing is None:
            # Segunda barrera: titulos muy reformulados de otros periodicos,
            # incluso si la noticia anterior ya se borro en Telegram.
            prior=previous_story({"event_id":eid,"title":card["title"],
                                  "source_url":card.get("source_url")},treated_refs)
            if prior:
                print("TTI_TREATED_STORY_BLOCKED",eid,
                      "previous_id="+str(prior.get("event_id") or ""),flush=True)
                skipped+=1
                continue
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
        # An empty ledger on deployment must NEVER backfill old provisional cards.
        # A FINAL TTiTTulares row already visible in current Listas is different:
        # the bidirectional audit treats a missing Telegram counterpart as a
        # repairable incident, so allow that first send within MAX_AGE.
        started=date(card.get("start"))
        if existing is None and (not started or now-started>timedelta(hours=12)):
            if not (project=="ttittulares" and card.get("final") and started):
                skipped+=1;continue
        button_version=TTI_BUTTONS_VERSION if project=="ttittulares" else BUTTONS_VERSION
        # Archive-photo delivery is disabled for both editorial projects.
        # Keep old media identity only until it is cleaned from Telegram.
        card["image"]=""
        photo_url=""
        image_data=None
        old_photo=bool(existing and (existing.get("is_photo") or existing.get("image_sha256")))
        is_late_photo=False
        body=card["text"]
        if project in {"ttittulares","ttendencias"} and card["final"]:
            note=card.get("ai_note") or ""
            if note:body=body[:max(0,1024-len(note)-2)]+"\n\n"+note
        for obsolete_note in ("📷 Fotografía de archivo pendiente.",
                              "📷 Fotografía de archivo disponible.",
                              "📷 Fotografía de archivo añadida como respuesta."):
            body=body.replace(obsolete_note,"")
        body=body.strip()
        kb=keys(card,project)
        # The digest includes the actual displayed text, not an image URL that
        # was fetched but could not be sent. Preserve the same Telegram card ID.
        new_hash=hashlib.sha256((body+"|"+card["image"]).encode("utf-8")).hexdigest()
        if existing and existing.get("content_sha256")==new_hash:
            if int(existing.get("buttons_version") or 0)==button_version:
                if not (is_late_photo and image_data):
                    skipped+=1
                    continue
            else:
                # Keyboard-only changes do not create a second news card.
                delivered_at=date(existing.get("delivered_at"))
                if (not delivered_at or now-delivered_at>timedelta(hours=48)):
                    skipped+=1;continue
                if not (is_late_photo and image_data):
                    result=send(token,"editMessageReplyMarkup",{
                        "chat_id":chat,"message_id":int(existing["telegram_message_id"]),
                        "reply_markup":kb})
                    if result:
                        existing.update({"buttons_version":button_version,
                                         "updated_at":now.isoformat()})
                        updated+=1
                    continue
        if existing:
            mid=int(existing["telegram_message_id"])
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
            if result and result.get("_telegram_message_gone"):
                # Telegram confirms that the provisional card no longer exists.
                # Keep the stale ledger row only as superseded history and create
                # exactly one replacement card for the same event/revision.
                replacement=send(token,"sendMessage",{"chat_id":chat,"text":body,
                    "reply_markup":kb})
                if not replacement or not replacement.get("message_id"):
                    continue
                existing.update({"status":"superseded","final":True,
                                 "superseded_at":now.isoformat(),
                                 "updated_at":now.isoformat()})
                entries.append({"delivery_key":f"{eid}:r{rev}:readonly-recovered",
                    "event_id":eid,"revision":rev,"title":card["title"],"name":card["title"],
                    "telegram_message_id":int(replacement["message_id"]),"status":"sent",
                    "is_photo":False,"image_url":"",
                    "content_sha256":new_hash,"final":card["final"],
                    "buttons_version":button_version,
                    "started_at":str(card["start"]),"delivered_at":now.isoformat(),
                    "source_url":str(card.get("source_url") or "")})
                delivered+=1
                if project=="ttittulares":
                    treated_refs.append(entries[-1])
                    if active_entries is not entries:active_entries.append(entries[-1])
                ledger["updated_at"]=now.isoformat()
                print("TTI_MISSING_CARD_RECREATED",eid,
                      "old_message_id="+str(mid),
                      "new_message_id="+str(replacement["message_id"]),flush=True)
                continue
            if not result:continue
            existing.update({"title":card["title"],"name":card["title"],
                             "source_url":str(card.get("source_url") or existing.get("source_url") or ""),
                             "content_sha256":new_hash,"final":card["final"],
                             "buttons_version":button_version,"updated_at":now.isoformat(),
                             "revision":rev,"is_photo":old_photo})
            updated+=1
        else:
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
                "content_sha256":new_hash,"final":card["final"],"buttons_version":button_version,
                "started_at":str(card["start"]),"delivered_at":now.isoformat(),
                "source_url":str(card.get("source_url") or "")})
            delivered+=1
            # Los dos ids pueden aparecer en el MISMO lote; incorporar
            # cada mensaje nuevo a ambos indices sin esperar otra ejecucion.
            if project=="ttittulares":
                treated_refs.append(entries[-1])
                if active_entries is not entries:active_entries.append(entries[-1])
        ledger["updated_at"]=now.isoformat()
    # Never silently delete a SECOND card only because a previous related
    # card was removed by the user. Its own Telegram message must be
    # completed with verified information or reported as blocked.
    # Consolidate already-posted sibling messages AFTER the leader exists.
    # Never delete a sibling merely for sharing a picture or being in a batch:
    # explicit editor-verified group identity is required.
    if project=="ttendencias":
        for group in cards:
            members=set(str(v) for v in group.get("group_member_ids") or [])
            leader_id=str(group.get("id") or "")
            if not group.get("final") or leader_id not in members or len(members)<2:
                continue
            leader=next((row for row in reversed(active_entries) if
                str(row.get("event_id") or "")==leader_id and
                str(row.get("status") or "").lower()=="sent" and
                int(row.get("telegram_message_id") or 0)>0),None)
            if not leader:continue
            if leader.get("group_id")!=group["group_id"] or leader.get("group_member_ids")!=group["group_member_ids"]:
                leader.update(group_id=group["group_id"],
                              group_member_ids=group["group_member_ids"],
                              group_title=group["title"],
                              updated_at=now.isoformat())
                updated+=1
            for sibling in active_entries:
                sibling_id=str(sibling.get("event_id") or "")
                if sibling_id==leader_id or sibling_id not in members:
                    continue
                if str(sibling.get("status") or "").lower()!="sent":
                    continue
                if finalize_existing_group_message(
                        sibling,group,group["text"],leader_id,now,token,chat):
                    sibling.update(group_id=group["group_id"])
                    updated+=1
                    ledger["updated_at"]=now.isoformat()
    # Explicit group membership is durable in BOTH the requests and the
    # Explicit group membership is durable in BOTH the requests and the
    # leader's explained record. A refresh may mark the follower inactive or
    # deleted after the editor finishes; do not require status=explained here.
    if project=="ttendencias":
        doc=load("trends/requests.json",{"requests":[]})
        by_id={str(req.get("id") or ""):req
               for req in doc.get("requests",[]) if req.get("id")}
        aliases={}
        for follower_id,req in by_id.items():
            if req.get("grouped_into_existing_card") is not True:
                continue
            leader_id=str(req.get("group_leader_id") or "")
            group_id=str(req.get("explanation_group_id") or req.get("group_id") or "")
            if leader_id and leader_id!=follower_id and group_id:
                aliases[follower_id]=(leader_id,group_id,int(req.get("revision") or 0))
        manual=load("trends/telegram-manual-explained.json",{"items":[]})
        for row in manual.get("items",[]) or []:
            leader_id=str(row.get("group_leader_id") or row.get("id") or "")
            group_id=str(row.get("explanation_group_id") or row.get("group_id") or "")
            members=row.get("grouped_member_revisions") or []
            # Require persisted explicit leader+member linkage; a similar
            # title or shared image is NOT enough to delete any Telegram card.
            if not leader_id or not group_id or len(members)<2 or not any(
                str(m.get("id") or "")==leader_id
                for m in members if isinstance(m,dict)):
                continue
            for member in members:
                if not isinstance(member,dict):
                    continue
                follower_id=str(member.get("id") or "")
                if follower_id and follower_id!=leader_id:
                    aliases[follower_id]=(leader_id,group_id,int(member.get("revision") or 0))
        for follower_id,(leader_id,group_id,linked_revision) in aliases.items():
            leader_req=by_id.get(leader_id)
            if leader_req:
                their_group=str(leader_req.get("explanation_group_id") or leader_req.get("group_id") or "")
                if their_group and their_group!=group_id:
                    continue
            # The leader may be historical (<= lifecycle watermark) while the
            # follower provisional is a new live message. Use the full durable
            # ledger only as proof of the explicit group's leader state; never
            # edit that historical leader. The follower loop below remains
            # restricted to active_entries, so no archived message is revived.
            leaders=[row for row in entries
                     if str(row.get("event_id") or "")==leader_id and
                     (str(row.get("status") or "").lower() in TERMINAL or
                      (str(row.get("status") or "").lower()=="sent" and
                       row.get("final") is True))]
            if not leaders:
                continue
            leader_delivery=leaders[-1]
            leader_status=str(leader_delivery.get("status") or "").lower()
            for ghost in active_entries:
                if (str(ghost.get("event_id") or "")!=follower_id or
                    str(ghost.get("status") or "").lower()!="sent" or
                    ghost.get("final") is True or
                    int(ghost.get("revision") or 0)!=linked_revision):
                    continue
                current_req=by_id.get(follower_id) or {}
                if (str(current_req.get("status") or "").lower() in {"preparing","update"} and
                    int(current_req.get("revision") or 0)>linked_revision):
                    continue
                explanation=str(current_req.get("explanation") or "").strip()
                if not explanation:
                    explanation=next((str(r.get("explanation") or "").strip()
                        for r in manual.get("items",[]) if
                        str(r.get("id") or "")==leader_id and
                        str(r.get("explanation") or "").strip()),"")
                if not explanation:
                    continue # auditor alerts; never delete the pending card.
                title=str(ghost.get("title") or ghost.get("name") or
                          current_req.get("name") or follower_id)
                label=title
                body=(label+"\n\nExplicación contrastada (compartida con "+
                      str((leader_req or {}).get("name") or leader_id)+"):\n\n"+
                      trim(explanation,780))
                if finalize_existing_group_message(
                        ghost,{"title":title,"search":title},
                        body,leader_id,now,token,chat):
                    ghost.update(group_id=group_id)
                    updated+=1
                    ledger["updated_at"]=now.isoformat()
    if delivered or updated:put(path,ledger)
    print(f"TELEGRAM_READONLY {project} delivered={delivered} updated={updated} skipped={skipped}",flush=True)
    return delivered,updated

def selftest():
    now=datetime(2026,10,9,16,0,tzinfo=timezone.utc)
    assert not age_ready("2026-10-09T15:01:00Z",now)
    assert age_ready("2026-10-09T15:00:00Z",now)
    assert not fresh("2026-09-29T12:00:00Z",now)
    # Prepared 14:00 after selection 01:00: eligible as a fresh Listas card.
    selected={"selected_at":"2026-10-08T01:00:00Z"}
    ready={"prepared_at":"2026-10-11T14:00:00Z","revision":1}
    assert news_delivery_start(selected,ready)=="2026-10-11T14:00:00Z"
    assert news_delivery_start(selected,{**ready,"rewrite_pending":True})=="2026-10-08T01:00:00Z"
    assert age_ready(news_delivery_start(selected,{}),now)

    card={"id":"abc123","rev":1,"search":"Pedro Sánchez","title":"Pedro Sánchez",
          "final":True,"x_text":"Hecho verificado.\n\n🌶️ Remate exacto."}
    kb=keys({**card,"image":"https://img.example.org/photo.jpg"},"ttittulares")["inline_keyboard"]
    assert [b["text"] for b in kb[0]]==["📄 GAG completo (copiar)","🎨 Chat Images"]
    assert [b["text"] for row in kb for b in row].count("🎨 Chat Images")==1
    assert not any("GAG rápido" in b["text"] for row in kb for b in row)
    assert [b["text"] for b in kb[1]]==["📋 Copiar en X","↗ Abrir en X"]
    assert [b["text"] for b in kb[2]]==["🔎 Buscar en X"]
    assert kb[0][0]["url"].startswith("https://fabricelop.github.io/europapress-rss/gag.html")
    assert kb[-1][0]["callback_data"]=="tt:b:abc123"
    no_photo=keys(card,"ttittulares")["inline_keyboard"]
    assert not any("Copiar imagen" in b["text"] for row in no_photo for b in row)
    assert not any("GAG rápido" in b["text"] for row in no_photo for b in row)
    trends_kb=keys({**card,"image":"https://img.example.org/photo.jpg"},"ttendencias")["inline_keyboard"]
    assert [b["text"] for b in trends_kb[0]]==["📄 GAG completo (copiar)","🎨 Chat Images"]
    assert not any("GAG rápido" in b["text"] for row in trends_kb for b in row)
    assert [b["text"] for b in trends_kb[1]]==["📋 Copiar en X","↗ Abrir en X"]
    assert trends_kb[1][0]["copy_text"]["text"]==card["x_text"]
    assert [b["text"] for b in trends_kb[2]]==["🔎 Buscar en X"]
    assert trends_kb[-2][0]["callback_data"]=="tx:r:abc123:1"
    assert trends_kb[-1][0]["callback_data"]=="tx:b:abc123:1"
    trends_no_photo=keys(card,"ttendencias")["inline_keyboard"]
    assert not any("Copiar foto" in b["text"] for row in trends_no_photo for b in row)
    long_card={**card,"x_text":"A"*270}
    long_x=keys(long_card,"ttendencias")["inline_keyboard"][1][0]
    assert "copy_text" not in long_x and "mode=x" in long_x["url"]
    assert len(keys(long_card,"ttendencias")["inline_keyboard"][1][1]["url"])<2048
    draft=provisional_news_copy({"verified_source_count":0},"Noticia urgente por verificar")
    assert "VERIFICACIÓN" in draft and len(draft)<=256
    verified_draft=provisional_news_copy({"verified_source_count":2,
        "factual_summary":"El ayuntamiento anunció una medida."},"Noticia urgente")
    assert "EN ELABORACIÓN" in verified_draft and "anunció" in verified_draft
    provisional={**card,"final":False,"x_text":draft,
                 "source_url":"https://www.example.org/noticias/noticia"}
    pending=keys(provisional,"ttittulares")["inline_keyboard"]
    assert [row[0]["text"] for row in pending]==[
        "📄 GAG completo (copiar)","📋 Copiar borrador para X",
        "🔎 Buscar en X","🔗 Fuente original","🗑️ Borrar"]
    assert pending[0][1]["text"]=="🎨 Chat Images"
    assert pending[1][0]["copy_text"]["text"]==draft
    assert "intent/tweet" in pending[1][1]["url"]
    assert pending[2][0]["text"]=="🔎 Buscar en X"
    assert pending[-1][0]["callback_data"]=="tt:b:abc123"
    no_source=keys({**provisional,"source_url":""},"ttittulares")["inline_keyboard"]
    assert [row[0]["text"] for row in no_source]==[
        "📄 GAG completo (copiar)","📋 Copiar borrador para X",
        "🔎 Buscar en X","🗑️ Borrar"]
    photo_pending=keys({**provisional,"image":"https://img.example.org/news.jpg"},"ttittulares")["inline_keyboard"]
    assert photo_pending[2][0]["text"]=="🔎 Buscar en X"
    pending_trends=keys({**card,"final":False,"x_text":""},"ttendencias")["inline_keyboard"]
    assert [row[0]["text"] for row in pending_trends]==["🔎 Buscar en X","🗑️ Borrar"]
    import tempfile
    original_root=ROOT
    original_send=send
    original_fast=fast_archive_from_article
    original_archive=archival_image
    methods=[]
    message_sequence=[991,992,993,994]
    def synthetic_send(token,method,payload,photo=None):
        methods.append((method,int(payload.get("message_id") or 0),
                        int(payload.get("reply_to_message_id") or 0),bool(photo)))
        return {"message_id":(message_sequence.pop(0) if method in {"sendMessage","sendPhoto"}
                               else int(payload.get("message_id") or 0))}
    try:
        globals()["fast_archive_from_article"]=lambda url:""
        globals()["archival_image"]=lambda url:(
            (b"jpeg","image/jpeg","photo.jpg") if url.startswith("https://img.example.org/")
            else None)

        with tempfile.TemporaryDirectory() as folder:
            globals()["ROOT"]=Path(folder)
            put("telegram/editorial-processing.json",{"items":[{
                "event_id":"urgent123","status":"PROCESSING","title":"Urgencia aún en elaboración",
                "selected_at":"2026-10-09T15:59:00Z","verified_source_count":2,
                "factual_summary":"Un organismo confirmó la medida.",
                "url":"https://www.example.org/noticias/urgencia"}]})
            put("ttittulares/prepared.json",{"items":[]})
            put("ttittulares/decisions.json",{"items":[]})
            provisional_rows=list(news_cards(now))
            assert len(provisional_rows)==1 and not provisional_rows[0]["final"]
            assert provisional_rows[0]["text"]=="🟠 EN ELABORACIÓN\n\nUrgencia aún en elaboración"
            assert "Fuente:" not in provisional_rows[0]["text"]
            assert "confirmó" not in provisional_rows[0]["text"]
            assert not provisional_rows[0]["image"]
            assert "confirmó" in provisional_rows[0]["x_text"]
            globals()["send"]=synthetic_send
            n_sent,n_updated=process("ttittulares",now,"mock","mockchat")
            assert (n_sent,n_updated)==(1,0)
            assert methods==[("sendMessage",0,0,False)]
            pending_ledger=load("telegram/ttittulares-deliveries.json",{"items":[]})
            assert len(pending_ledger["items"])==1
            assert not pending_ledger["items"][0]["final"]
            assert pending_ledger["items"][0]["telegram_message_id"]==991
            # En Elaboración NO enviar fotos ni siquiera si el archivo ya aparece.
            # La imagen de archivo se adjuntará únicamente cuando pase a Listas.
            job=load("telegram/editorial-processing.json",{"items":[]})
            job["items"][0]["archive_image"]={"url":"https://img.example.org/late.jpg",
                "generated":False}
            put("telegram/editorial-processing.json",job)
            before=len(methods)
            n_sent,n_updated=process("ttittulares",now,"mock","mockchat")
            assert (n_sent,n_updated)==(0,0)
            assert len(methods)==before
            updated_ledger=load("telegram/ttittulares-deliveries.json",{"items":[]})
            assert not updated_ledger["items"][0].get("archive_telegram_message_id")
            final={"event_id":"urgent123","title":"Urgencia aún en elaboración",
                "revision":2,"prepared_at":"2026-10-09T16:00:00Z",
                "tweet":{"text":"Un organismo confirmó la medida.",
                         "remate":"🌶️ Remate exacto."},
                "factual_summary":"Un organismo confirmó la medida."}
            put("ttittulares/prepared.json",{"items":[final]})
            finished=list(news_cards(now))
            assert len(finished)==1 and finished[0]["final"]
            assert "Remate exacto" in finished[0]["text"]
            n_sent,n_updated=process("ttittulares",now,"mock","mockchat")
            assert (n_sent,n_updated)==(0,1), "A final item must EDIT the first message"
            assert methods[-1:]==[("editMessageText",991,0,False)]
            assert not any(method=="sendPhoto" for method,*_ in methods)
            final_ledger=load("telegram/ttittulares-deliveries.json",{"items":[]})
            assert len(final_ledger["items"])==1, "Never send a duplicate Telegram card"
            assert final_ledger["items"][0]["telegram_message_id"]==991
            assert final_ledger["items"][0]["final"]
            assert final_ledger["items"][0]["revision"]==2
            assert not final_ledger["items"][0].get("archive_telegram_message_id")
            # Foto disponible desde el principio: solo titular en Elaboración.
            # Al pasar a Listas, se añade una única fotografía como respuesta.
            put("telegram/editorial-processing.json",{"items":[{
                "event_id":"photo123","status":"PROCESSING","title":"Urgencia con foto inicial",
                "selected_at":"2026-10-09T15:59:00Z","archive_image":{
                    "url":"https://img.example.org/early.jpg","generated":False}
            }]})
            put("ttittulares/prepared.json",{"items":[]})
            n_sent,n_updated=process("ttittulares",now,"mock","mockchat")
            assert n_sent==1 and methods[-1]==("sendMessage",0,0,False)
            ledger=load("telegram/ttittulares-deliveries.json",{"items":[]})
            new=next(x for x in ledger["items"] if x["event_id"]=="photo123")
            assert not new["is_photo"] and new["telegram_message_id"]==992
            assert len(ledger["items"])==2
            put("ttittulares/prepared.json",{"items":[{
                "event_id":"photo123","revision":2,
                "prepared_at":"2026-10-09T16:00:00Z",
                "title":"Urgencia con foto inicial",
                "factual_summary":"El organismo confirmó los datos.",
                "tweet":{"text":"El organismo confirmó los datos.",
                         "remate":"🌶️ Remate aprobado."},
                "archive_image":{"url":"https://img.example.org/early.jpg",
                                 "generated":False}
            }]})
            before=len(methods)
            n_sent,n_updated=process("ttittulares",now,"mock","mockchat")
            assert (n_sent,n_updated)==(0,1)
            assert methods[before:]==[("editMessageText",992,0,False)]
            ledger=load("telegram/ttittulares-deliveries.json",{"items":[]})
            updated_photo=next(x for x in ledger["items"] if x["event_id"]=="photo123")
            assert updated_photo["telegram_message_id"]==992 and updated_photo["final"]
            assert not updated_photo.get("archive_telegram_message_id")
            assert len(ledger["items"])==2,"Final photo must edit the first card"
    finally:
        globals()["ROOT"]=original_root
        globals()["send"]=original_send
        globals()["fast_archive_from_article"]=original_fast
        globals()["archival_image"]=original_archive
    assert not trend_repeat_allowed({"is_in_top":True,"entered_top_at":"2026-10-09T13:00:00Z"},
        [{"status":"sent","delivered_at":"2026-10-09T12:00:00Z"}],now)
    assert trend_repeat_allowed({"novelty_verified":True,"is_in_top":True,
        "entered_top_at":"2026-10-01T00:00:00Z"},
        [{"status":"sent","delivered_at":"2026-10-01T00:00:00Z"}],now)
    assert not trend_repeat_allowed({"is_in_top":False,"entered_top_at":"2026-10-07T00:00:00Z"},
        [{"status":"sent","delivered_at":"2026-10-07T00:00:00Z"}],now)
    assert trend_title_key("Diomandé")=="diomande"  # Nonempty: catches escaped-regex bug.
    assert trend_title_key("Diomande")=="diomande"
    assert trend_title_key("Dónde ver")=="dondever"
    assert recently_delivered_same_title(
        {"id":"new-id","title":"Diomandé"},
        [{"event_id":"old-id","title":"Diomande","status":"deleted",
          "telegram_message_id":644,"delivered_at":"2026-10-09T15:00:00Z"}],now)
    # The similarity helper still detects a prior related deletion; TTiTTulares process() no longer uses it to suppress a distinct active card.
    tombstone={"event_id":"anfield-old","name":"Anfield","status":"deleted",
               "delivered_at":"2026-10-11T17:19:28Z","deleted_at":"2026-10-11T17:38:32Z",
               "telegram_message_id":674}
    assert matching_previous_story({"id":"anfield-new","title":"Anfield"},
        [tombstone],datetime(2026,10,11,18,0,tzinfo=timezone.utc)) is tombstone
    assert matching_previous_story({"id":"anfield-new","title":"Anfield"},
        [{**tombstone,"status":"published"}],
        datetime(2026,10,11,18,0,tzinfo=timezone.utc))
    assert not matching_previous_story({"id":"new","title":"Elche"},
        [tombstone],datetime(2026,10,11,18,0,tzinfo=timezone.utc))
    assert not recently_delivered_same_title(
        {"id":"same-id","title":"Diomande"},
        [{"event_id":"same-id","title":"Diomande","status":"sent",
          "telegram_message_id":644,"delivered_at":"2026-10-09T15:00:00Z"}],now)
    assert recently_delivered_same_title(
        {"id":"news2","title":"Dónde ver el Real Madrid - Villarreal"},
        [{"event_id":"news1","title":"Donde ver el Real Madrid Villarreal","status":"sent",
          "telegram_message_id":3323,"delivered_at":"2026-10-09T15:00:00Z"}],now)
    assert recently_delivered_same_title(
        {"id":"news3","title":"Cambio de titular","source_url":"https://www.example.com/noticia?id=1"},
        [{"event_id":"news1","title":"Titular anterior",
          "source_url":"https://example.com/noticia?utm_source=telegram",
          "telegram_message_id":3323,"delivered_at":"2026-10-09T15:00:00Z"}],now)
    assert not trend_repeat_allowed(
        {"novelty_verified":True,"is_in_top":True,"entered_top_at":"2026-10-07T00:00:00Z"},
        [{"status":"sent","delivered_at":"2026-10-09T15:00:00Z"}],now)
    # Regression: same Racing-Valencia episode had 4 request IDs and 4
    # Telegram photos, despite only ONE editorial explanation. Consolidate
    # only when the explicit persisted group metadata matches.
    original_root=ROOT
    original_send=send
    original_archive=archival_image
    import tempfile
    try:
        with tempfile.TemporaryDirectory() as folder:
            globals()["ROOT"]=Path(folder)
            members=[("raba","Raba",1,687),("corberan","Corberan",4,688),
                     ("racing","Racing",5,689),("aguirre","Aguirre",9,691)]
            group_id="grp-raba"
            explanation=("TT#1 Raba es tendencia porque marcó al 2' ante Racing "
                         "en el debut de Aguirre tras el cese de Corberán.\n"
                         "🌶️ Un gol abrió la función.")
            reqs=[]
            ledger=[]
            for mid,name,rank,tgmid in members:
                reqs.append({"id":mid,"name":name,"rank":rank,"status":"explained",
                             "revision":0,"requested_at":now.isoformat(),
                             "explained_at":now.isoformat(),
                             "explanation":explanation,"group_id":group_id,
                             "explanation_group_id":group_id,
                             "group_leader_id":"raba","auto_queued":True,
                             "archive_image":{"url":"https://img.example.org/raba.jpg"}})
                ledger.append({"event_id":mid,"name":name,"title":name,"revision":0,
                               "status":"sent","final":True,
                               "telegram_message_id":tgmid,"is_photo":True,
                               "image_url":"https://img.example.org/raba.jpg",
                               "content_sha256":"old","delivered_at":now.isoformat()})
            put("trends/requests.json",{"requests":reqs})
            put("trends/recent.json",{"items":[
                {"name":name,"rank":rank} for mid,name,rank,tgmid in members]})
            put("trends/telegram-manual-explained.json",{"items":[{
                "id":"raba","status":"explained","revision":0,
                "explained_at":now.isoformat(),"explanation":explanation,
                "closer_text":"🌶️ Un gol abrió la función.",
                "group_id":group_id,"explanation_group_id":group_id,
                "group_leader_id":"raba",
                "grouped_member_revisions":[{"id":mid,"revision":0}
                                            for mid,*_ in members]}]})
            put("trends/explained.json",{"items":[]})
            put("trends/telegram-image-deliveries.json",{"items":ledger})
            cards=list(trend_cards(now))
            assert len(cards)==1,cards
            assert cards[0]["group_member_ids"]==["raba","corberan","racing","aguirre"]
            assert all(term in cards[0]["text"] for term in
                       ("Raba","Corberan","Racing","Aguirre"))
            assert "Todas se relacionan con el mismo acontecimiento" in cards[0]["text"]
            assert cards[0]["text"].count("🌶️") == 1
            operations=[]
            def fake_send(token,method,payload,photo=None):
                operations.append((method,int(payload.get("message_id") or 0)))
                return {"message_id":int(payload.get("message_id") or 0)}
            globals()["send"]=fake_send
            globals()["archival_image"]=lambda url:(
                (b"jpeg","image/jpeg","raba.jpg")
                if url=="https://img.example.org/raba.jpg" else None)
            count=process("ttendencias",now,"mock","chat")
            assert count[0]==0,count
            assert [mid for method,mid in operations if method=="editMessageCaption"]==[687,688,689,691],operations
            fixed=load("trends/telegram-image-deliveries.json",{"items":[]})
            assert len([x for x in fixed["items"] if x["status"]=="sent"])==4
            assert len([x for x in fixed["items"] if x.get("final") is True])==4
            assert next(x for x in fixed["items"] if x["status"]=="sent")["telegram_message_id"]==687
            operations.clear()
            process("ttendencias",now,"mock","chat")
            assert not operations,operations
            print("TT_GROUP_SINGLE_EVENT_SINGLE_TELEGRAM_SELFTEST_OK")
    finally:
        globals()["ROOT"]=original_root
        globals()["send"]=original_send
        globals()["archival_image"]=original_archive
    assert public_news_detail({"explanation":"Reuters y Associated Press coinciden en la noticia. Ambas fuentes corroboran los datos.","factual_summary":"El comité anunció el premio."})=="El comité anunció el premio."
    assert public_news_detail({"explanation":"La comisión ha aprobado un informe.","factual_summary":"Informe aprobado."})=="La comisión ha aprobado un informe."
    assert trend_body("TT#14 #Sitges2026","TT#14 #Sitges2026 es tendencia por un festival.\\n🌶️ Remate.",True).count("TT#14")==1
    assert trend_body("TT#14 #Sitges2026","",False).count("TT#14")==1
    assert verified_article_urls({"verification_sources":[{"url":"https://sitgesfilmfestival.com/es"},{"url":"https://www.culturasitges.cat/actualitat/noticies/edicion"}]})==["https://www.culturasitges.cat/actualitat/noticies/edicion","https://sitgesfilmfestival.com/es"]
    assert archival_image("") is None
    assert "#Actualidad" not in "\n\n".join(x["text"] for x in news_cards(now))
    assert "#Actualidad" not in "\n\n".join(x["text"] for x in trend_cards(now))
    # Both pending routes send their first card immediately; the final
    # explanation edits the same Telegram message rather than duplicating it.
    original_root=ROOT
    original_send=send
    original_archive=archival_image
    import tempfile
    try:
        with tempfile.TemporaryDirectory() as folder:
            globals()["ROOT"]=Path(folder)
            reqs=[
                {"id":"pending-top1","name":"Prueba Top 10","rank":1,
                 "status":"preparing","revision":1,"auto_queued":True,
                 "requested_at":now.isoformat()},
                {"id":"pending-manual12","name":"Prueba manual","rank":12,
                 "status":"preparing","revision":1,"auto_queued":False,
                 "request_source":"github_pages_authorized_issue",
                 "requested_at":now.isoformat()},
                {"id":"ignored-13","name":"No solicitada","rank":13,
                 "status":"preparing","revision":1,"auto_queued":True,
                 "requested_at":now.isoformat()}]
            put("trends/requests.json",{"requests":reqs})
            put("trends/recent.json",{"items":[
                {"name":"Prueba Top 10","rank":1},
                {"name":"Prueba manual","rank":12},
                {"name":"No solicitada","rank":13}]})
            put("trends/telegram-manual-explained.json",{"items":[]})
            put("trends/explained.json",{"items":[]})
            put("trends/telegram-image-deliveries.json",{"items":[]})
            cards=list(trend_cards(now))
            assert len(cards)==2 and all(not c["final"] for c in cards),cards
            assert all("Pendiente de explicación" in c["text"] for c in cards)
            calls=[]
            next_id=[2400]
            def fake_trend_send(token,method,payload,photo=None):
                mid=int(payload.get("message_id") or 0)
                if not mid:
                    next_id[0]+=1
                    mid=next_id[0]
                calls.append((method,mid))
                return {"message_id":mid}
            globals()["send"]=fake_trend_send
            globals()["archival_image"]=lambda url:None
            assert process("ttendencias",now,"mock","chat")==(2,0)
            ledger=load("trends/telegram-image-deliveries.json",{"items":[]})
            assert len(ledger["items"])==2 and all(not x["final"] for x in ledger["items"])
            first_mid=next(x["telegram_message_id"] for x in ledger["items"]
                           if x["event_id"]=="pending-manual12")
            reqs[1].update(status="explained",
                explanation="TT#12 Prueba manual es tendencia porque se verificó el hecho.",
                explained_at=now.isoformat())
            put("trends/requests.json",{"requests":reqs})
            assert process("ttendencias",now,"mock","chat")==(0,1)
            assert calls[-1]==("editMessageText",first_mid),calls
            ledger=load("trends/telegram-image-deliveries.json",{"items":[]})
            assert len(ledger["items"])==2
            final=next(x for x in ledger["items"] if x["event_id"]=="pending-manual12")
            assert final["telegram_message_id"]==first_mid and final["final"]
            assert process("ttendencias",now,"mock","chat")==(0,0)
            print("TT_TRENDS_IMMEDIATE_PENDING_EDIT_IN_PLACE_SELFTEST_OK")
    finally:
        globals()["ROOT"]=original_root
        globals()["send"]=original_send
        globals()["archival_image"]=original_archive
    # Previously deleted *related* cards do not grant permission to
    # remove the new Telegram message. Finish its own message in place.
    original_root=ROOT
    original_send=send
    original_archive=archival_image
    import tempfile
    try:
        with tempfile.TemporaryDirectory() as folder:
            globals()["ROOT"]=Path(folder)
            # Regression: an explicit group leader can be an archived/old
            # Telegram message while a newly selected follower has a live
            # provisional. The historic leader is proof of grouping only;
            # the live follower must still be finalized in place.
            put("telegram/lifecycle-baseline.json",{
                "activated_at":"2026-10-09T15:30:00Z",
                "project_state":{"ttendencias":{
                    "historic_max_message_id":712,
                    "preserve_pending_ids":["arrasate"]}}})
            put("trends/requests.json",{"requests":[
                {"id":"jagoba","name":"Jagoba","status":"deleted",
                 "group_leader_id":"jagoba","group_id":"grp-jagoba"},
                {"id":"arrasate","name":"Jagoba Arrasate","rank":5,
                 "status":"explained","revision":0,
                 "group_id":"grp-jagoba","group_leader_id":"jagoba",
                 "grouped_into_existing_card":True,
                 "explanation":"El equipo ha anunciado el regreso de Arrasate."}]})
            put("trends/recent.json",{"items":[{"name":"Jagoba Arrasate","rank":5}]})
            put("trends/telegram-manual-explained.json",{"items":[]})
            put("trends/explained.json",{"items":[]})
            put("trends/telegram-image-deliveries.json",{"items":[
                {"event_id":"jagoba","revision":0,"status":"deleted",
                 "final":True,"telegram_message_id":710,
                 "delivered_at":now.isoformat()},
                {"event_id":"arrasate","revision":0,"status":"sent",
                 "final":False,"telegram_message_id":714,
                 "delivered_at":now.isoformat()}]})
            operations=[]
            def fake_sender(token,method,payload,photo=None):
                operations.append((method,int(payload.get("message_id") or 0)))
                return {"message_id":int(payload.get("message_id") or 0)}
            globals()["send"]=fake_sender
            globals()["archival_image"]=lambda url:None
            assert process("ttendencias",now,"mock","mockchat")==(0,1)
            assert operations==[("editMessageText",714)],operations
            ledger=load("trends/telegram-image-deliveries.json",{"items":[]})
            ghost=next(x for x in ledger["items"] if x["event_id"]=="arrasate")
            assert ghost["status"]=="sent" and ghost["final"] is True
            assert process("ttendencias",now,"mock","mockchat")==(0,0)
            assert operations==[("editMessageText",714)]
            print("TT_GROUP_ORPHAN_FINAL_IN_PLACE_SELFTEST_OK")
    finally:
        globals()["ROOT"]=original_root
        globals()["send"]=original_send
        globals()["archival_image"]=original_archive
    # Duplicate problem != user deletion for that exact Telegram message.
    original_root=ROOT
    original_send=send
    original_archive=archival_image
    import tempfile
    try:
        with tempfile.TemporaryDirectory() as folder:
            globals()["ROOT"]=Path(folder)
            put("ttittulares/prepared.json",{"items":[]})
            put("telegram/editorial-processing.json",{"items":[]})
            put("ttittulares/decisions.json",{"items":[]})
            put("ttittulares/status.json",{"problematic_items":[{
                "event_id":"4a294ec12ff5","revision":1,
                "problem_reason":"Coincide con evento previamente borrado",
                "user_validated":False}]})
            put("telegram/ttittulares-deliveries.json",{"items":[
                {"event_id":"4e8026a01ba6","revision":1,"status":"deleted",
                 "final":True,"telegram_message_id":3550,
                 "delivered_at":now.isoformat()},
                {"event_id":"4a294ec12ff5","revision":1,"status":"sent",
                 "final":False,"is_photo":True,
                 "telegram_message_id":3555,
                 "delivered_at":now.isoformat()}]})
            operations=[]
            globals()["send"]=lambda token,method,payload,photo=None:operations.append(method)
            globals()["archival_image"]=lambda url:None
            assert process("ttittulares",now,"token","chat")==(0,0)
            assert operations==[],operations
            ledger=load("telegram/ttittulares-deliveries.json",{})
            assert ledger["items"][1]["status"]=="sent"
            print("TTI_PROVISIONAL_NEVER_AUTO_DELETE_SELFTEST_OK")
    finally:
        globals()["ROOT"]=original_root
        globals()["send"]=original_send
        globals()["archival_image"]=original_archive
    # A newly verified story with an existing provisional can be finished
    # even if a DIFFERENT earlier ID was deleted by the user. No new send.
    original_root=ROOT
    original_send=send
    original_archive=archival_image
    import tempfile
    try:
        with tempfile.TemporaryDirectory() as folder:
            globals()["ROOT"]=Path(folder)
            put("telegram/editorial-processing.json",{"items":[]})
            put("ttittulares/decisions.json",{"items":[]})
            put("ttittulares/prepared.json",{"items":[{
                "event_id":"fresh-sol","revision":1,
                "title":"Sol: tensión y cordón policial",
                "prepared_at":now.isoformat(),
                "factual_summary":"La Policía separó a los dos grupos.",
                "tweet":{"text":"La Policía separó a los dos grupos.",
                         "remate":"🌶️ El cordón tuvo que continuar."}}]})
            put("telegram/ttittulares-deliveries.json",{"items":[
                {"event_id":"old-sol","title":"Sol: tensión y cordón policial",
                 "status":"deleted","final":True,
                 "telegram_message_id":400,
                 "delivered_at":now.isoformat()},
                {"event_id":"fresh-sol","title":"Sol: tensión y cordón policial",
                 "status":"sent","final":False,
                 "revision":1,"telegram_message_id":401,
                 "delivered_at":now.isoformat()}]})
            operations=[]
            def mocked_send(token,method,payload,photo=None):
                operations.append((method,int(payload.get("message_id") or 0)))
                return {"message_id":int(payload.get("message_id") or 0)}
            globals()["send"]=mocked_send
            globals()["archival_image"]=lambda url:None
            assert process("ttittulares",now,"mock","mockchat")==(0,1)
            assert operations==[("editMessageText",401)],operations
            ledger=load("telegram/ttittulares-deliveries.json",{"items":[]})
            assert ledger["items"][0]["status"]=="deleted"
            assert ledger["items"][1]["status"]=="sent" and ledger["items"][1]["final"] is True
            print("TT_DUPLICATE_VERIFIED_FINAL_IN_PLACE_SELFTEST_OK")
    finally:
        globals()["ROOT"]=original_root
        globals()["send"]=original_send
        globals()["archival_image"]=original_archive
    # An empty-chat checkpoint archives old cards, but keeps four explicitly
    # awaiting trends, even if their requested_at precedes the reset moment.
    original_root=ROOT
    import tempfile
    try:
        with tempfile.TemporaryDirectory() as tmp:
            globals()["ROOT"]=Path(tmp)
            put("telegram/lifecycle-baseline.json",{
                "activated_at":"2026-10-12T15:25:23Z",
                "project_state":{
                    "ttittulares":{"historic_max_message_id":3559,
                                   "preserve_pending_ids":[]},
                    "ttendencias":{"historic_max_message_id":717,
                                   "preserve_pending_ids":["pending-4"]}}})
            assert not baseline_allows(
                "ttittulares","historical","2026-10-12T15:00:00Z")
            assert baseline_allows(
                "ttittulares","new","2026-10-12T15:26:00Z")
            assert baseline_allows(
                "ttendencias","pending-4","2026-10-12T15:22:26Z")
            assert not baseline_allows(
                "ttendencias","obsolete","2026-10-12T15:22:26Z")
            ledger=[{"event_id":"old","telegram_message_id":717,
                     "status":"sent","final":True},
                    {"event_id":"new","telegram_message_id":720,
                     "status":"sent","final":False}]
            active=active_delivery_rows("ttendencias",ledger)
            assert len(active)==1 and active[0]["event_id"]=="new"
            print("TT_LIFECYCLE_RESET_SELFTEST_OK")
    finally:
        globals()["ROOT"]=original_root
    # A revised group explanation must not re-edit every already-finalized
    # sibling: Fofana/Robbie Ure/#LevanteSevilla remain separate user cards,
    # but only the canonical leader gets subsequent editorial updates.
    sibling={"event_id":"fofana","telegram_message_id":735,
             "status":"sent","final":True,"grouped_into":"levante-sevilla",
             "content_sha256":"old"}
    assert finalize_existing_group_message(sibling,
        {"id":"levante-sevilla","title":"Levante-Sevilla","search":"Fofana"},
        "Resultado definitivo 3-3","levante-sevilla",now,
        "mock-token","mock-chat") is False
    assert sibling["content_sha256"]=="old"
    print("TT_GROUP_NO_FINAL_SIBLING_FANOUT_SELFTEST_OK")
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
