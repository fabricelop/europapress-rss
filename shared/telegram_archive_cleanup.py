#!/usr/bin/env python3
"""Remove ONLY archive photographs from the two editorial Telegram bots.

This is deliberately separate from TTImageRelay/TTImages (Chrome 9234).
Execute Telegram operations once, then apply confirmed results to a fresh
ledger without repeating API calls on git-push conflicts.
"""
import argparse
import json
import os
from pathlib import Path
from datetime import datetime, timezone, timedelta
import requests
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from shared import telegram_readonly_delivery as delivery

LEDGER={
    "ttittulares":"telegram/ttittulares-deliveries.json",
    "ttendencias":"trends/telegram-image-deliveries.json",
}
REPORT={
    "ttittulares":"telegram/cleanup-archive-media-ttittulares.json",
    "ttendencias":"telegram/cleanup-archive-media-ttendencias.json",
}
def nowz():
    return datetime.now(timezone.utc).isoformat()

def api(token,method,payload):
    r=requests.post(f"https://api.telegram.org/bot{token}/{method}",json=payload,timeout=25)
    try: response=r.json()
    except ValueError: response={"ok":False,"description":"Respuesta no JSON de Telegram"}
    if not response.get("ok"):
        raise RuntimeError(str(response.get("description","Telegram failed"))[:250])
    return response.get("result")

def is_recent(row,stamp_key="delivered_at"):
    stamp=delivery.date(row.get(stamp_key) or row.get("delivered_at"))
    return bool(stamp and timedelta(seconds=-120)<=
                datetime.now(timezone.utc)-stamp<timedelta(hours=47))

def inventory(project):
    now=datetime.now(timezone.utc)
    try:
        cards=(delivery.news_cards(now) if project=="ttittulares"
               else delivery.trend_cards(now))
        return {str(c["id"]):c for c in cards}
    except Exception as exc:
        print("TT_ARCHIVE_CARDS_WARNING",project,str(exc)[:180],flush=True)
        return {}

def prepare(project):
    token=os.environ.get("TELEGRAM_BOT_TOKEN" if project=="ttittulares" else "TTENDENCIAS_BOT_TOKEN","")
    chat=os.environ.get("TELEGRAM_CHAT_ID" if project=="ttittulares" else "TTENDENCIAS_CHAT_ID","")
    if project=="ttendencias" and not chat:
        chat=str(delivery.load("trends/telegram-bot-state.json",{}).get("chat_id") or "")
    if not token or not chat:
        raise RuntimeError(f"Faltan token/chat de {project}. No se ejecuta ninguna eliminacion.")
    return token,chat

def execute(project,filename):
    token,chat=prepare(project)
    cards=inventory(project)
    rows=delivery.load(LEDGER[project],{"items":[]}).get("items",[])
    changes=[]
    skipped=[]
    errors=[]
    for row in rows:
        if str(row.get("status") or "").lower()!="sent":
            continue
        eid=str(row.get("event_id") or "")
        mid=int(row.get("telegram_message_id") or 0)
        if not mid:continue
        photo=bool(row.get("is_photo"))
        companion=int(row.get("archive_telegram_message_id") or 0)
        if not photo and not companion and int(row.get("buttons_version") or 0)>=(
                delivery.TTI_BUTTONS_VERSION if project=="ttittulares" else delivery.BUTTONS_VERSION):
            continue
        op={"event_id":eid,"revision":int(row.get("revision") or 0),
            "original_id":mid}
        if companion:
            if is_recent(row,"archive_attached_at"):
                try:
                    api(token,"deleteMessage",{"chat_id":chat,"message_id":companion})
                    op["archive_deleted_id"]=companion
                except Exception as exc:
                    errors.append({"event_id":eid,"archive_message_id":companion,
                                   "reason":str(exc)})
            else:
                skipped.append({"event_id":eid,"archive_message_id":companion,
                                "reason":"Telegram normalmente no permite borrar mensajes de mas de 48h"})
        card=cards.get(eid)
        if photo:
            if not is_recent(row):
                skipped.append({"event_id":eid,"message_id":mid,
                                "reason":"Foto original anterior a 48h, borrado no permitido por Bot API"})
                # Aunque la foto no se pueda borrar, retirar al menos su boton de copia.
                new_version=(delivery.TTI_BUTTONS_VERSION if project=="ttittulares"
                             else delivery.BUTTONS_VERSION)
                if int(row.get("buttons_version") or 0)<new_version:
                    fallback={"id":eid,"rev":int(row.get("revision") or 0),
                              "search":str(row.get("title") or row.get("name") or ""),
                              "title":str(row.get("title") or ""),
                              "final":False,"x_text":""}
                    try:
                        api(token,"editMessageReplyMarkup",{
                            "chat_id":chat,"message_id":mid,
                            "reply_markup":delivery.keys(card or fallback,project)})
                        op["buttons_replaced"]=True
                    except Exception as exc:
                        if "message is not modified" in str(exc).lower():
                            op["buttons_replaced"]=True
                        else:
                            errors.append({"event_id":eid,"message_id":mid,
                                           "reason":"No se pudo retirar boton antiguo: "+str(exc)})
            else:
                replacement=0
                try:
                    if card:
                        text=str(card.get("text") or "").strip()
                        note=str(card.get("ai_note") or "").strip()
                        if note and card.get("final"):
                            text=(text+"\n\n"+note)[:4000]
                        if not text:
                            raise RuntimeError("Tarjeta editorial sin texto; no eliminar mensaje original")
                        result=api(token,"sendMessage",{
                            "chat_id":chat,"text":text[:4000],
                            "disable_web_page_preview":True,
                            "reply_markup":delivery.keys({**card,"image":""},project)})
                        replacement=int(result.get("message_id") or 0)
                        if not replacement:
                            raise RuntimeError("Telegram no confirmo ID de texto sustituto")
                    api(token,"deleteMessage",{"chat_id":chat,"message_id":mid})
                    op["original_photo_deleted"]=True
                    if replacement:op["replacement_message_id"]=replacement
                except Exception as exc:
                    if replacement:
                        try:api(token,"deleteMessage",{"chat_id":chat,"message_id":replacement})
                        except Exception as rollback:
                            errors.append({"event_id":eid,"replacement_id":replacement,
                                           "reason":"No se pudo revertir sustituto: "+str(rollback)})
                    errors.append({"event_id":eid,"message_id":mid,"reason":str(exc)})
        elif card:
            try:
                api(token,"editMessageReplyMarkup",{
                    "chat_id":chat,"message_id":mid,
                    "reply_markup":delivery.keys({**card,"image":""},project)})
                op["buttons_replaced"]=True
            except Exception as exc:
                if "message is not modified" in str(exc).lower():
                    op["buttons_replaced"]=True
                else:
                    errors.append({"event_id":eid,"message_id":mid,"reason":str(exc)})
        if len(op)>3:changes.append(op)
    report={"version":1,"project":project,"executed_at":nowz(),
            "confirmed_changes":changes,"skipped":skipped,"errors":errors}
    Path(filename).write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf8")
    print("TT_ARCHIVE_REMOVAL",project,"confirmed",len(changes),"skipped",len(skipped),
          "errors",len(errors),flush=True)
    for issue in errors[:15]:
        print("TT_ARCHIVE_ERROR",json.dumps(issue,ensure_ascii=False),flush=True)

def apply(project,filename):
    report=json.loads(Path(filename).read_text(encoding="utf8"))
    assert report.get("project")==project
    doc=delivery.load(LEDGER[project],{"items":[]})
    rows=doc.setdefault("items",[])
    changed=0
    for op in report.get("confirmed_changes",[]):
        row=next((r for r in rows if str(r.get("event_id") or "")==op["event_id"]
                    and int(r.get("telegram_message_id") or 0) in
                    {op["original_id"],op.get("replacement_message_id",0)}),None)
        if not row:continue
        if "archive_deleted_id" in op and int(row.get("archive_telegram_message_id") or 0)==op["archive_deleted_id"]:
            row.pop("archive_telegram_message_id",None)
            row.pop("archive_image_url",None)
            row["archive_media_removed_at"]=report["executed_at"]
            changed+=1
        if op.get("original_photo_deleted"):
            row["is_photo"]=False
            row["image_url"]=""
            row.pop("image_sha256",None)
            if op.get("replacement_message_id"):
                row["telegram_message_id"]=op["replacement_message_id"]
                row["content_sha256"]=""
                row["buttons_version"]=0  # force a real content refresh
            else:
                row["status"]="removed" # no current card: do not resurrect it
            row["archive_media_removed_at"]=report["executed_at"]
            changed+=1
        if op.get("buttons_replaced") and str(row.get("status") or "")=="sent":
            row["buttons_version"]=(delivery.TTI_BUTTONS_VERSION if project=="ttittulares"
                                    else delivery.BUTTONS_VERSION)
            row["updated_at"]=report["executed_at"]
            changed+=1
    if changed:
        doc["updated_at"]=report["executed_at"]
        delivery.put(LEDGER[project],doc)
    delivery.put(REPORT[project],{
        "version":1,"project":project,"last_run":report["executed_at"],
        "updated_rows":changed,"skipped":report.get("skipped",[]),
        "errors":report.get("errors",[])})
    print("TT_ARCHIVE_APPLY",project,changed,flush=True)

if __name__=="__main__":
    ap=argparse.ArgumentParser()
    ap.add_argument("project",choices=sorted(LEDGER))
    g=ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--execute",action="store_true")
    g.add_argument("--apply",action="store_true")
    ap.add_argument("--patch",required=True)
    a=ap.parse_args()
    (execute if a.execute else apply)(a.project,a.patch)
