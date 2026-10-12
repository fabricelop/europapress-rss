#!/usr/bin/env python3
"""Safely remove bot-authored technical receipts only when provenance is known.

Never enumerate arbitrary message IDs or delete a story, a pinned index,
an incoming user message, or a message without a bot-generated receipt.
Telegram deletes are possible only for supported messages (usually <48h).
"""
import json
import os
from pathlib import Path
from datetime import datetime,timezone,timedelta
from urllib.request import Request,urlopen
from urllib.error import HTTPError

ROOT=Path(__file__).resolve().parents[1]
REPORT="telegram/technical-cleanup-report.json"

def load(name,default):
    try:return json.loads((ROOT/name).read_text(encoding="utf8"))
    except (OSError,ValueError):return default

def save(name,doc):
    file=ROOT/name
    file.parent.mkdir(parents=True,exist_ok=True)
    file.write_text(json.dumps(doc,indent=2,ensure_ascii=False)+"\n",encoding="utf8")

def stamp(v):
    try:
        d=datetime.fromisoformat(str(v or "").replace("Z","+00:00"))
        if d.tzinfo is None:d=d.replace(tzinfo=timezone.utc)
        return d.astimezone(timezone.utc)
    except (TypeError,ValueError):return None

def candidates(now):
    ledger=load("telegram/ttittulares-deliveries.json",{"items":[]})
    other=load("trends/telegram-image-deliveries.json",{"items":[]})
    pinned=[load(f"telegram/pinned-index-{p}.json",{})
            for p in ("ttittulares","ttendencias")]
    blocked={int(x.get("message_id") or 0) for x in pinned}
    for entry in ledger.get("items",[]):
        for key in ("telegram_message_id","archive_telegram_message_id","cross_quote_message_id"):
            mid=int(entry.get(key) or 0)
            if mid:blocked.add(mid)
    # TTiTTulares uses different Telegram bot namespace than TTendencias.
    # Never reuse the same numeric IDs across projects for deletion.
    tti_reserved={int(entry.get(key) or 0)
                  for entry in ledger.get("items",[])
                  for key in ("telegram_message_id","archive_telegram_message_id","cross_quote_message_id")}
    tti_reserved.add(int(pinned[0].get("message_id") or 0))
    trends_reserved={int(entry.get(key) or 0)
                     for entry in other.get("items",[])
                     for key in ("telegram_message_id","archive_telegram_message_id")}
    trends_reserved.add(int(pinned[1].get("message_id") or 0))
    manifest=load("telegram/tt-technical-receipts.json",{"items":[]})
    found={}
    for row in manifest.get("items",[]):
        if str(row.get("kind") or "") not in {"run_ack","execution_ack","status_notice",
                "error_notice","orphan_audit_notice","maintenance_notice"}:continue
        if str(row.get("status") or "")=="deleted":continue
        project=str(row.get("project") or "")
        mid=int(row.get("message_id") or 0)
        at=stamp(row.get("created_at"))
        if project not in {"ttittulares","ttendencias"} or not mid or not at:continue
        if not timedelta(minutes=2)<=now-at<=timedelta(hours=47):continue
        if mid in (tti_reserved if project=="ttittulares" else trends_reserved):continue
        found[(project,mid)]={"project":project,"message_id":mid,
            "kind":row["kind"],"source":"bot_authored_receipt","created_at":at.isoformat()}
    # Current TTendencias listener records run/refresh acknowledgements with
    # exact bot API sendMessage result IDs in its persisted package state.
    trends_state=load("trends/telegram-package-listener-state.json",{})
    for row in trends_state.get("technical_notices",[]):
        if row.get("bot_authored") is not True:continue
        mid=int(row.get("message_id") or 0)
        at=stamp(row.get("created_at"))
        if (not mid or mid in trends_reserved or
                not at or not timedelta(minutes=2)<=now-at<=timedelta(hours=47)):
            continue
        found.setdefault(("ttendencias",mid),{
            "project":"ttendencias","message_id":mid,
            "kind":str(row.get("kind") or "status_notice"),
            "source":"verified_trend_bot_sendMessage",
            "created_at":at.isoformat()})
    # Historical mobile commands have explicit bot-notice message IDs.
    # The user's actual command message is cleanup_command_mid: NEVER delete it.
    for x in load("telegram/tt-mobile-command-queue.json",{"items":[]}).get("items",[]):
        if str(x.get("status") or "").lower()!="completed":continue
        mid=int(x.get("cleanup_notice_mid") or 0)
        at=stamp(x.get("completed_at") or x.get("submitted_at"))
        if not mid or mid in tti_reserved or not at:continue
        if not timedelta(minutes=2)<=now-at<=timedelta(hours=47):continue
        found.setdefault(("ttittulares",mid),{"project":"ttittulares",
            "message_id":mid,"kind":"execution_ack",
            "source":"completed_mobile_command_notice","created_at":at.isoformat()})
    # Exact bot-persisted legacy panel IDs, never guessed message sequences.
    panel=load("trends/telegram-bot-state.json",{})
    panel_ids=set()
    for value in list(panel.get("panel_message_ids") or [])+[panel.get("panel_message_id")]:
        try:
            mid=int(value or 0)
            if mid>0:panel_ids.add(mid)
        except (TypeError,ValueError):pass
    for mid in panel_ids-trends_reserved:
        found.setdefault(("ttendencias",mid),{
            "project":"ttendencias","message_id":mid,"kind":"legacy_panel",
            "source":"persisted_bot_panel_id","created_at":now.isoformat()})
    return list(found.values())

def telegram_delete(project,mid):
    env="TELEGRAM_BOT_TOKEN" if project=="ttittulares" else "TTENDENCIAS_BOT_TOKEN"
    chat_env="TELEGRAM_CHAT_ID" if project=="ttittulares" else "TTENDENCIAS_CHAT_ID"
    token=os.getenv(env,"")
    chat=os.getenv(chat_env,"")
    if not chat:
        # Authenticated index creation already persisted the exact private chat.
        index=load("telegram/pinned-index-"+project+".json",{})
        if index.get("pinned") is True:
            chat=str(index.get("chat_id") or "")
    if not token or not chat:raise RuntimeError("Bot credentials/chat not configured")
    url="https://api.telegram.org/bot"+token+"/deleteMessage"
    payload=json.dumps({"chat_id":str(chat),"message_id":mid}).encode()
    req=Request(url,data=payload,headers={"Content-Type":"application/json"})
    try:
        with urlopen(req,timeout=20) as res:
            response=json.load(res)
    except HTTPError as exc:
        # Existing message may already have been cleared manually.
        body=exc.read(600).decode(errors="replace").lower()
        if exc.code==400 and "message to delete not found" in body:
            return "not_found"
        if exc.code==400 and ("message can't be deleted" in body or "message cannot be deleted" in body):
            return "not_deletable"
        raise RuntimeError("Telegram delete HTTP "+str(exc.code)) from exc
    if response.get("ok") is not True:
        raise RuntimeError("Telegram delete not acknowledged")
    return "deleted"

def run(now=None,deleter=telegram_delete):
    now=now or datetime.now(timezone.utc)
    prev=load(REPORT,{})
    processed={str(x.get("project"))+":"+str(x.get("message_id")):x
               for x in prev.get("results",[])}
    results=[]
    deleted=0
    for row in candidates(now):
        key=row["project"]+":"+str(row["message_id"])
        old=processed.get(key,{})
        if old.get("result") in {"deleted","not_found","not_deletable","not_found_or_expired"}:
            results.append(old);continue
        try:
            status=deleter(row["project"],row["message_id"])
            if status=="deleted":deleted+=1
        except Exception as e:
            status="failed:"+type(e).__name__
        results.append({**row,"result":status,"checked_at":now.isoformat()})
    report={"checked_at":now.isoformat(),"candidates":len(results),
            "deleted_now":deleted,"results":results[-120:],
            "policy":"only bot-generated IDs recorded by existing receipts; never delete editorial cards, pinned indexes, user posts or inferred IDs"}
    save(REPORT,report)
    print("TT_TECHNICAL_CLEANUP candidates="+str(len(results))+
          " deleted="+str(deleted),flush=True)
    return report

def selftest():
    import tempfile
    global ROOT
    original=ROOT
    with tempfile.TemporaryDirectory() as td:
        ROOT=Path(td)
        try:
            now=datetime(2026,10,12,19,5,tzinfo=timezone.utc)
            save("telegram/ttittulares-deliveries.json",{"items":[
                {"telegram_message_id":222,"status":"sent","event_id":"a"}]})
            save("telegram/pinned-index-ttittulares.json",{"message_id":333})
            save("telegram/tt-technical-receipts.json",{"items":[
                {"project":"ttittulares","kind":"run_ack","message_id":444,
                 "created_at":"2026-10-12T18:30:00Z"},
                {"project":"ttittulares","kind":"run_ack","message_id":222,
                 "created_at":"2026-10-12T18:30:00Z"},
                {"project":"ttittulares","kind":"run_ack","message_id":333,
                 "created_at":"2026-10-12T18:30:00Z"}]})
            assert len(candidates(now))==1,candidates(now)
            seen=[]
            report=run(now,lambda p,mid:seen.append((p,mid)) or "deleted")
            assert report["deleted_now"]==1 and seen==[("ttittulares",444)]
            print("TT_TECHNICAL_CLEANUP_SELFTEST_OK")
        finally:ROOT=original

if __name__=="__main__":
    import sys
    if "selftest" in sys.argv:selftest()
    else:run()
