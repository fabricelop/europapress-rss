#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import sys
import urllib.parse
from datetime import datetime, timezone, timedelta

import requests
from PIL import Image
from io import BytesIO

ROOT=pathlib.Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0,str(ROOT))

from shared.cross_account_story import (
    build_ttendencias_quote_copy,
    find_published_news_match,
    x_account_search_url,
)
EXPLAINED=ROOT/"trends/telegram-manual-explained.json"
DELIVERIES=ROOT/"trends/telegram-image-deliveries.json"
BOT_STATE=ROOT/"trends/telegram-bot-state.json"
TTI_DELIVERIES=ROOT/"telegram/ttittulares-deliveries.json"
ARCHIVE_DIR=ROOT/"trends/archive-images"
WORKER="https://tt-control.fabricelop.workers.dev"
APP_URL=str(os.environ.get("TTENDENCIAS_APP_URL") or "https://europapress-rss-fabricelopezillac-9660.vercel.app").rstrip("/")
BUTTONS_VERSION=5
TERMINAL={"published","dismissed"}


def load(path, default):
    try:
        raw=path.read_text(encoding="utf-8").strip()
        return json.loads(raw) if raw else default
    except Exception:
        return default


def save(path, doc):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(doc,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")


def nowz():
    return datetime.now(timezone.utc).isoformat().replace("+00:00","Z")


def recent_visual(row, hours=6):
    cutoff=datetime.now(timezone.utc)-timedelta(hours=hours)
    for key in ("ai_image_last_attempt_at","explained_at"):
        v=row.get(key)
        if not v:
            continue
        try:
            dt=datetime.fromisoformat(str(v).replace("Z","+00:00")).astimezone(timezone.utc)
            if dt>=cutoff:
                return True
        except Exception:
            pass
    return False


def valid_ai(row):
    ai=row.get("ai_image") or {}
    url=str(ai.get("url") or "").strip()
    sha=str(ai.get("sha256") or "").strip().lower()
    if not (
        str(row.get("ai_image_status") or "").lower()=="ready"
        and str(ai.get("provider") or "")=="chat-imagegen"
        and str(ai.get("origin") or "")=="executing_chat"
        and int(ai.get("width") or 0)>=1024
        and int(ai.get("height") or 0)>=576
        and url and len(sha)==64
    ):
        return False
    try:
        raw=fetch_image(url)
        if hashlib.sha256(raw).hexdigest().lower()!=sha:
            return False
        with Image.open(BytesIO(raw)) as im:
            width,height=im.size
            im.verify()
        return (
            width>=1024 and height>=576
            and width==int(ai.get("width") or 0)
            and height==int(ai.get("height") or 0)
        )
    except Exception:
        return False


def package_text(row):
    explanation=str(row.get("explanation") or "").strip()
    closer=str(row.get("closer_text") or "").strip()
    if closer and closer not in explanation:
        explanation=(explanation+"\n"+closer).strip()
    return explanation


def image_source(row):
    for key in ("archive_image","fallback_image"):
        obj=row.get(key)
        if isinstance(obj,dict) and str(obj.get("url") or "").strip() and not obj.get("generated"):
            return obj
    return {}


def fetch_image(url):
    marker="/main/"
    if url.startswith("https://raw.githubusercontent.com/fabricelop/europapress-rss/") and marker in url:
        rel=urllib.parse.unquote(url.split(marker,1)[1])
        local=(ROOT/rel).resolve()
        try: local.relative_to(ROOT.resolve())
        except Exception: local=None
        if local and local.is_file():
            raw=local.read_bytes()
        else:
            raw=b""
    else:
        raw=b""
    if not raw:
        r=requests.get(url,timeout=35,headers={"User-Agent":"TTendencias-Telegram/1"},allow_redirects=True)
        r.raise_for_status()
        ct=str(r.headers.get("content-type") or "").lower()
        if ct and not ct.startswith("image/"):
            raise RuntimeError("No es imagen: "+ct)
        raw=r.content
    img=Image.open(BytesIO(raw))
    img.verify()
    return raw


def ext_and_mime(raw):
    im=Image.open(BytesIO(raw))
    fmt=(im.format or "JPEG").upper()
    if fmt=="PNG": return ".png","image/png"
    if fmt=="WEBP": return ".webp","image/webp"
    return ".jpg","image/jpeg"


def materialize_archive(tid,rev,raw):
    sha=hashlib.sha256(raw).hexdigest()
    ext,_=ext_and_mime(raw)
    rel=pathlib.Path("trends/archive-images")/f"{tid}-r{rev}-{sha[:12]}{ext}"
    path=ROOT/rel
    path.parent.mkdir(parents=True,exist_ok=True)
    if not path.exists():
        path.write_bytes(raw)
    url="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"+str(rel).replace("\\","/")
    return sha,str(rel),url


def telegram_api(token,method,payload=None,files=None):
    url=f"https://api.telegram.org/bot{token}/{method}"
    if files:
        r=requests.post(url,data=payload,files=files,timeout=45)
    else:
        r=requests.post(url,json=payload,timeout=35)
    try: out=r.json()
    except Exception: out={"ok":False,"description":r.text[:500]}
    if not r.ok or not out.get("ok"):
        raise RuntimeError(f"Telegram {method}: {out}")
    return out.get("result")


def send_photo(token,chat,raw,caption,keyboard=None):
    ext,mime=ext_and_mime(raw)
    data={"chat_id":str(chat),"caption":caption}
    if keyboard:
        data["reply_markup"]=json.dumps(keyboard,ensure_ascii=False,separators=(",",":"))
    return telegram_api(token,"sendPhoto",data,{"photo":("ttendencias"+ext,raw,mime)})


def send_text(token,chat,text,keyboard=None):
    payload={"chat_id":str(chat),"text":text,"disable_web_page_preview":True}
    if keyboard:
        payload["reply_markup"]=keyboard
    return telegram_api(token,"sendMessage",payload)


def delete_message(token,chat,message_id):
    if not message_id:
        return
    try:
        telegram_api(token,"deleteMessage",{
            "chat_id":str(chat),
            "message_id":int(message_id),
        })
    except Exception as e:
        if "message to delete not found" not in str(e).lower():
            raise


def edit_photo_media(token,chat,message_id,raw,caption,keyboard=None):
    ext,mime=ext_and_mime(raw)
    media={"type":"photo","media":"attach://photo","caption":caption}
    data={
        "chat_id":str(chat),
        "message_id":int(message_id),
        "media":json.dumps(media,ensure_ascii=False,separators=(",",":")),
    }
    if keyboard:
        data["reply_markup"]=json.dumps(keyboard,ensure_ascii=False,separators=(",",":"))
    return telegram_api(token,"editMessageMedia",data,{"photo":("ttendencias"+ext,raw,mime)})


def edit_keyboard(token,chat,message_id,keyboard):
    try:
        return telegram_api(token,"editMessageReplyMarkup",{
            "chat_id":str(chat),"message_id":int(message_id),"reply_markup":keyboard
        })
    except Exception as e:
        if "message is not modified" in str(e).lower():
            return None
        raise


def q(url,params):
    return url+"?"+urllib.parse.urlencode(params)


def x_search_url(term):
    return "https://x.com/search?"+urllib.parse.urlencode({
        "q":str(term or "").strip(),
        "src":"typed_query",
        "f":"live",
    })


def trend_search_term(row):
    names=[str(x or "").strip() for x in (row.get("trend_names") or []) if str(x or "").strip()]
    if names:
        return names[0]
    return str(row.get("name") or "").strip()


def reexplain_url(tid,rev):
    return APP_URL+"/ttendencias/explicadas/?"+urllib.parse.urlencode({
        "open":f"{tid}:r{int(rev)}",
        "reexplain":"1",
    })


def keyboard(tid,rev,text,ai_url="",archive_url="",search_term="",timeout_fallback=False,archive_only=False):
    rows=[]
    if timeout_fallback or archive_only:
        if archive_url:
            rows.append([{"text":"🗂️ Copiar imagen archivo","url":q(WORKER+"/copy-image",{"src":archive_url})}])
    else:
        rows.append([{"text":"🖼️ Copiar imagen IA","url":q(WORKER+"/copy-image",{"src":ai_url})}])
        if archive_url:
            rows.append([{"text":"🗂️ Copiar imagen archivo","url":q(WORKER+"/copy-image",{"src":archive_url})}])
    if len(text)<=256:
        copy_button={"text":"📋 Copiar texto","copy_text":{"text":text}}
    else:
        copy_button={"text":"📋 Copiar texto","url":q(WORKER+"/copy-text",{"text":text})}
    rows.append([
        copy_button,
        {"text":"✍️ Abrir en X","url":q(WORKER+"/x-compose",{"text":text})}
    ])
    action_row=[]
    if str(search_term or "").strip():
        action_row.append({"text":"🔎 Buscar en X","url":x_search_url(search_term)})
    action_row.append({"text":"🔄 Reexplicar","url":reexplain_url(tid,rev)})
    rows.append(action_row)
    if timeout_fallback:
        rows.append([{"text":"🔄 Reenviar a Listas","callback_data":f"tx:r:{tid}:{rev}"}])
    rows.append([
        {"text":"🗑️ Desestimar","callback_data":f"tx:d:{tid}:{rev}"},
        {"text":"✅ Publicado","callback_data":f"tx:p:{tid}:{rev}"}
    ])
    return {"inline_keyboard":rows}



def cross_quote_keyboard(tid,rev,text,search_url,timeout_fallback=False):
    if len(text)<=256:
        copy_button={"text":"📋 Copiar texto","copy_text":{"text":text}}
    else:
        copy_button={"text":"📋 Copiar texto","url":q(WORKER+"/copy-text",{"text":text})}
    return {"inline_keyboard":[
        [
            copy_button,
            {"text":"✍️ Abrir en X","url":q(WORKER+"/x-compose",{"text":text})},
        ],
        [
            {"text":"🔎 Buscar en @ttittulares","url":search_url},
            {"text":"🔄 Reexplicar","url":reexplain_url(tid,rev)},
        ],
        *([[{"text":"🔄 Reenviar a Listas","callback_data":f"tx:r:{tid}:{rev}"}]] if timeout_fallback else []),
        [
            {"text":"🗑️ Desestimar","callback_data":f"tx:d:{tid}:{rev}"},
            {"text":"✅ Publicado","callback_data":f"tx:p:{tid}:{rev}"},
        ],
    ]}


def cross_quote_for_trend(row,text,tti_deliveries):
    subject=trend_search_term(row)
    match=find_published_news_match(
        text,
        subject,
        tti_deliveries,
        hours=48,
        threshold=0.55,
    )
    if not match:
        return None
    quote_text=build_ttendencias_quote_copy(text)
    if not quote_text:
        print("TTENDENCIAS_CROSS_QUOTE_SKIP_LONG",str(row.get("id") or ""),flush=True)
        return None
    search_url=x_account_search_url(
        "ttittulares",
        match.get("text") or "",
        text,
        subject,
    )
    return {
        "text":quote_text,
        "search_url":search_url,
        "score":float(match.get("score") or 0),
        "source_event_id":str(match.get("id") or ""),
        "source_published_at":str(match.get("published_at") or ""),
    }


def build_patch(base_doc,current_doc,changed_keys):
    rows=[]
    for row in current_doc.get("items",[]):
        if str(row.get("delivery_key") or "") in changed_keys:
            rows.append(row)
    return {"version":1,"updated_at":nowz(),"rows":rows}


def run_send(patch_path):
    token=str(os.environ.get("TTENDENCIAS_BOT_TOKEN") or "").strip()
    if not token:
        raise SystemExit("Falta TTENDENCIAS_BOT_TOKEN")
    state=load(BOT_STATE,{})
    chat=state.get("chat_id")
    if not chat:
        raise SystemExit("TTendencias no tiene chat_id enlazado")

    explained=load(EXPLAINED,{"items":[]})
    copy_state=load(ROOT/"trends/explained-copy-state.json",{"items":[]})
    archived=set()
    for x in copy_state.get("items",[]):
        rev=int(x.get("revision") or 0)
        for name in x.get("trend_names") or []:
            archived.add((str(name or "").strip().casefold(),rev))
    deliveries=load(DELIVERIES,{"version":1,"items":[]})
    deliveries.setdefault("items",[])
    tti_deliveries=load(TTI_DELIVERIES,{"items":[]})
    changed=set()
    touched=0

    for row in explained.get("items",[]):
        if str(row.get("status") or "").lower()!="explained":
            continue
        if (str(row.get("name") or "").strip().casefold(),int(row.get("revision") or 0)) in archived:
            continue
        if row.get("tremending_origin") or row.get("telegram_package_suppress"):
            continue
        if str(row.get("telegram_package_status") or "").lower() in TERMINAL:
            continue
        cutoff=datetime.now(timezone.utc)-timedelta(hours=24)
        try:
            at=datetime.fromisoformat(str(row.get("explained_at") or "").replace("Z","+00:00")).astimezone(timezone.utc)
            if at < cutoff:
                continue
        except Exception:
            continue
        tid=str(row.get("id") or "").strip()
        rev=int(row.get("revision") or 0)
        if not tid:
            continue
        text=package_text(row)
        if not text:
            continue
        if len(text)>280:
            print("TTENDENCIAS_TELEGRAM_SKIP_LONG",tid,len(text),flush=True)
            continue

        ai_ok=valid_ai(row)
        retry_version=int(row.get("ai_image_regenerate_request_version") or 0)
        retry_at=None
        try:
            if row.get("ai_image_regenerate_requested_at"):
                retry_at=datetime.fromisoformat(str(row.get("ai_image_regenerate_requested_at")).replace("Z","+00:00")).astimezone(timezone.utc)
        except Exception:
            retry_at=None
        wait_from=max([x for x in (at,retry_at) if x is not None])
        timeout_ready=(datetime.now(timezone.utc)-wait_from)>=timedelta(minutes=90)

        if not ai_ok:
            if not timeout_ready:
                continue
            key=f"{tid}:r{rev}:timeout:v{retry_version}"
            existing=next((d for d in reversed(deliveries.get("items",[])) if str(d.get("delivery_key") or "")==key),None)
            if existing and str(existing.get("status") or "").lower() in {"sent","published","dismissed","retry_requested","superseded"}:
                continue

            archive=image_source(row)
            archive_src=str(archive.get("url") or "").strip()
            archive_copy_url=""
            archive_sha=""
            archive_raw=None
            if archive_src:
                try:
                    archive_raw=fetch_image(archive_src)
                    archive_sha,_,archive_copy_url=materialize_archive(tid,rev,archive_raw)
                except Exception as e:
                    print("TTENDENCIAS_TIMEOUT_ARCHIVE_WARNING",tid,str(e),flush=True)
                    archive_raw=None

            kb=keyboard(tid,rev,text,"",archive_copy_url,trend_search_term(row),timeout_fallback=True)
            cross=cross_quote_for_trend(row,text,tti_deliveries)
            cross_mid=0
            if cross:
                ckb=cross_quote_keyboard(tid,rev,cross["text"],cross["search_url"],timeout_fallback=True)
                cmsg=send_text(
                    token,chat,
                    "🔁 CITA CRUZADA · citar @ttittulares\n\n"
                    +cross["text"]+f"\n\n{len(cross['text'])}/280",
                    ckb,
                )
                cross_mid=int(cmsg.get("message_id") or 0)
                print("TTENDENCIAS_CROSS_QUOTE_SENT",tid,cross_mid,"score",cross["score"],flush=True)
            note="\n\n⏳ Más de 90 min sin imagen IA."
            try:
                if archive_raw:
                    msg=send_photo(token,chat,archive_raw,text+note,kb)
                else:
                    msg=send_text(token,chat,text+note,kb)
            except Exception:
                if cross_mid:
                    delete_message(token,chat,cross_mid)
                raise
            mid=int(msg.get("message_id") or 0)
            delivery={
                "delivery_key":key,
                "event_id":tid,
                "revision":rev,
                "name":str(row.get("name") or ""),
                "telegram_message_id":mid,
                "delivered_at":nowz(),
                "status":"sent",
                "buttons_version":BUTTONS_VERSION,
                "timeout_fallback":True,
                "timeout_retry_version":retry_version,
                "timeout_wait_from":wait_from.isoformat().replace("+00:00","Z"),
            }
            if cross_mid:
                delivery.update({
                    "cross_quote_message_id":cross_mid,
                    "cross_quote_source":"@ttittulares",
                    "cross_quote_text":cross["text"],
                    "cross_quote_search_url":cross["search_url"],
                    "cross_quote_score":cross["score"],
                    "cross_quote_source_event_id":cross["source_event_id"],
                    "cross_quote_source_published_at":cross["source_published_at"],
                })
            if archive_src:
                delivery.update({
                    "archive_image_url":archive_src,
                    "archive_materialized_url":archive_copy_url,
                    "archive_sha256":archive_sha,
                })
            deliveries["items"].append(delivery)
            changed.add(key)
            touched+=1
            print("TTENDENCIAS_TELEGRAM_TIMEOUT_SENT",tid,mid,"archive",bool(archive_raw),flush=True)
            continue

        ai=row.get("ai_image") or {}
        ai_url=str(ai.get("url") or "").strip()
        ai_sha=str(ai.get("sha256") or "").strip().lower()
        key=f"{tid}:r{rev}:{ai_sha}"

        exact=None
        event_sent=None
        for d in reversed(deliveries.get("items",[])):
            if str(d.get("event_id") or "")==tid and int(d.get("revision") or 0)==rev and str(d.get("status") or "").lower()=="sent" and event_sent is None:
                event_sent=d
            if str(d.get("delivery_key") or "")==key:
                exact=d
                break

        if exact and str(exact.get("status") or "").lower() in TERMINAL:
            continue

        # Si el aviso provisional de 90 min sigue visible, se conserva como
        # mensaje de ARCHIVO. La IA llegará como un segundo mensaje independiente.
        timeout_archive=None
        if event_sent and event_sent.get("timeout_fallback"):
            timeout_archive=event_sent

        archive=image_source(row)
        archive_src=str(archive.get("url") or "").strip()
        if timeout_archive:
            archive_mid=int(timeout_archive.get("telegram_message_id") or 0)
            archive_copy_url=str(timeout_archive.get("archive_materialized_url") or "")
            archive_sha=str(timeout_archive.get("archive_sha256") or "")
        else:
            archive_mid=int((exact or {}).get("archive_telegram_message_id") or 0)
            archive_copy_url=str((exact or {}).get("archive_materialized_url") or "")
            archive_sha=str((exact or {}).get("archive_sha256") or "")

        if archive_src and not archive_copy_url:
            try:
                raw=fetch_image(archive_src)
                archive_sha,_,archive_copy_url=materialize_archive(tid,rev,raw)
            except Exception as e:
                print("TTENDENCIAS_ARCHIVE_MATERIALIZE_WARNING",tid,str(e),flush=True)

        if archive_src and not archive_mid:
            try:
                raw=fetch_image(archive_src)
                if not archive_copy_url:
                    archive_sha,_,archive_copy_url=materialize_archive(tid,rev,raw)
                msg=send_photo(token,chat,raw,"🗂️ Imagen de archivo · "+str(row.get("name") or "TTendencias"))
                archive_mid=int(msg.get("message_id") or 0)
                print("TTENDENCIAS_ARCHIVE_SENT",tid,archive_mid,flush=True)
            except Exception as e:
                print("TTENDENCIAS_ARCHIVE_WARNING",tid,str(e),flush=True)

        kb=keyboard(tid,rev,text,ai_url,archive_copy_url,trend_search_term(row))

        if timeout_archive:
            try:
                archive_kb=keyboard(tid,rev,text,"",archive_copy_url,trend_search_term(row),archive_only=True)
                edit_keyboard(token,chat,int(timeout_archive.get("telegram_message_id") or 0),archive_kb)
                timeout_archive["buttons_version"]=BUTTONS_VERSION
                timeout_archive["buttons_updated_at"]=nowz()
                timeout_archive["ai_companion_pending"]=False
                changed.add(str(timeout_archive.get("delivery_key") or ""))
            except Exception as e:
                print("TTENDENCIAS_TIMEOUT_ARCHIVE_KEYBOARD_WARNING",tid,str(e),flush=True)

        if exact and str(exact.get("status") or "").lower()=="sent":
            edit_keyboard(token,chat,int(exact.get("telegram_message_id") or 0),kb)
            updates={
                "buttons_version":BUTTONS_VERSION,
                "buttons_updated_at":nowz(),
            }
            if archive_mid:
                updates.update({
                    "archive_telegram_message_id":archive_mid,
                    "archive_image_url":archive_src,
                    "archive_materialized_url":archive_copy_url,
                    "archive_sha256":archive_sha,
                    "archive_delivered_at":exact.get("archive_delivered_at") or nowz(),
                })
            row_changed=False
            for k,v in updates.items():
                if exact.get(k)!=v:
                    exact[k]=v
                    row_changed=True
            if row_changed:
                changed.add(key)
            touched+=1
            continue

        raw=fetch_image(ai_url)
        got=hashlib.sha256(raw).hexdigest()
        if got.lower()!=ai_sha:
            raise RuntimeError(f"{tid}: SHA256 IA no coincide")

        cross=None
        cross_mid=0
        if not int((timeout_archive or {}).get("cross_quote_message_id") or 0):
            cross=cross_quote_for_trend(row,text,tti_deliveries)
        if cross:
            ckb=cross_quote_keyboard(tid,rev,cross["text"],cross["search_url"])
            cmsg=send_text(
                token,chat,
                "🔁 CITA CRUZADA · citar @ttittulares\n\n"
                +cross["text"]+f"\n\n{len(cross['text'])}/280",
                ckb,
            )
            cross_mid=int(cmsg.get("message_id") or 0)
            print("TTENDENCIAS_CROSS_QUOTE_SENT",tid,cross_mid,"score",cross["score"],flush=True)

        caption=text+f"\n\n{len(text)}/280"
        try:
            msg=send_photo(token,chat,raw,caption,kb)
        except Exception:
            if cross_mid:
                delete_message(token,chat,cross_mid)
            raise
        mid=int(msg.get("message_id") or 0)
        delivery={
            "delivery_key":key,
            "event_id":tid,
            "revision":rev,
            "name":str(row.get("name") or ""),
            "image_sha256":got,
            "image_url":ai_url,
            "telegram_message_id":mid,
            "delivered_at":nowz(),
            "status":"sent",
            "buttons_version":BUTTONS_VERSION,
        }
        if cross_mid:
            delivery.update({
                "cross_quote_message_id":cross_mid,
                "cross_quote_source":"@ttittulares",
                "cross_quote_text":cross["text"],
                "cross_quote_search_url":cross["search_url"],
                "cross_quote_score":cross["score"],
                "cross_quote_source_event_id":cross["source_event_id"],
                "cross_quote_source_published_at":cross["source_published_at"],
            })
        if archive_mid:
            delivery.update({
                "archive_telegram_message_id":archive_mid,
                "archive_image_url":archive_src,
                "archive_materialized_url":archive_copy_url,
                "archive_sha256":archive_sha,
                "archive_delivered_at":(timeout_archive or {}).get("delivered_at") or nowz(),
            })
        deliveries["items"].append(delivery)
        changed.add(key)
        touched+=1
        print("TTENDENCIAS_TELEGRAM_SENT",tid,mid,"archive",archive_mid,"chars",len(text),flush=True)

    deliveries["items"]=deliveries.get("items",[])[-500:]
    deliveries["count"]=len(deliveries["items"])
    deliveries["version"]=1
    if changed:
        deliveries["updated_at"]=nowz()
        save(DELIVERIES,deliveries)
    patch=build_patch({},deliveries,changed)
    save(pathlib.Path(patch_path),patch)
    print("TTENDENCIAS_TELEGRAM_PATCH_ROWS="+str(len(patch["rows"])),flush=True)
    print("TTENDENCIAS_TELEGRAM_TOUCHED="+str(touched),flush=True)


def apply_patch(patch_path):
    current=load(DELIVERIES,{"version":1,"items":[]})
    patch=load(pathlib.Path(patch_path),{"rows":[]})
    items=current.setdefault("items",[])
    by={str(x.get("delivery_key") or ""):x for x in items if x.get("delivery_key")}
    for incoming in patch.get("rows",[]):
        key=str(incoming.get("delivery_key") or "")
        if not key:
            continue
        existing=by.get(key)
        if existing is None:
            copy=dict(incoming)
            items.append(copy)
            by[key]=copy
            continue
        terminal=str(existing.get("status") or "").lower() in TERMINAL
        terminal_fields={}
        if terminal:
            for k in ("status","published_at","dismissed_at","decision_source"):
                if k in existing:
                    terminal_fields[k]=existing[k]
        existing.update(incoming)
        if terminal:
            existing.update(terminal_fields)
    current["version"]=1
    current["items"]=items[-500:]
    current["count"]=len(current["items"])
    current["updated_at"]=patch.get("updated_at") or current.get("updated_at")
    save(DELIVERIES,current)


def selftest():
    kb=keyboard("abc123",2,"TT#1 Demo es tendencia porque ocurre algo.\n🌶️ Remate.","https://example.com/ai.png","https://example.com/archive.jpg","Demo")
    rows=kb.get("inline_keyboard") or []
    labels=[b.get("text") for row in rows for b in row]
    expected={"🖼️ Copiar imagen IA","🗂️ Copiar imagen archivo","📋 Copiar texto","✍️ Abrir en X","🔎 Buscar en X","🔄 Reexplicar","🗑️ Desestimar","✅ Publicado"}
    if not expected.issubset(set(labels)):
        raise SystemExit("SELFTEST keyboard incompleto: "+repr(labels))
    callbacks=[b.get("callback_data") for row in rows for b in row if b.get("callback_data")]
    if "tx:d:abc123:2" not in callbacks or "tx:p:abc123:2" not in callbacks:
        raise SystemExit("SELFTEST callbacks tx incorrectos")
    search=[b for row in rows for b in row if b.get("text")=="🔎 Buscar en X"]
    if not search or "q=Demo" not in str(search[0].get("url") or ""):
        raise SystemExit("SELFTEST búsqueda X incorrecta")
    kb2=keyboard("abc123",2,"texto","https://example.com/ai.png","","")
    labels2=[b.get("text") for row in kb2.get("inline_keyboard",[]) for b in row]
    if "🗂️ Copiar imagen archivo" in labels2:
        raise SystemExit("SELFTEST botón archivo no debe aparecer sin archivo")
    if "🔎 Buscar en X" in labels2:
        raise SystemExit("SELFTEST búsqueda X no debe aparecer sin término")
    ck=cross_quote_keyboard("abc123",2,"Lo contamos en @ttittulares: Demo completa.","https://x.com/search?q=from%3Attittulares+Demo",timeout_fallback=True)
    clabels=[b.get("text") for row in ck.get("inline_keyboard",[]) for b in row]
    if "🖼️ Copiar imagen IA" in clabels or "🔎 Buscar en @ttittulares" not in clabels or "🔄 Reenviar a Listas" not in clabels:
        raise SystemExit("SELFTEST cita cruzada incorrecta")
    print("TTENDENCIAS_TELEGRAM_SELFTEST_OK",flush=True)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("mode",choices=["send","apply-patch","selftest"])
    ap.add_argument("--patch",default="/tmp/ttendencias-delivery-patch.json")
    args=ap.parse_args()
    if args.mode=="send":
        run_send(args.patch)
    elif args.mode=="apply-patch":
        apply_patch(args.patch)
    else:
        selftest()


if __name__=="__main__":
    main()
