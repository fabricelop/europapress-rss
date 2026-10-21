#!/usr/bin/env python3
"""Audit Telegram delivery ledgers after EACH TT sender execution.

Telegram Bot API cannot enumerate private chat history / getMessage.
This checks the results of actual bot deliveries and the editorial records,
then reports unresolved messages in Telegram, without deleting any card.
"""
import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

ROOT=Path(__file__).resolve().parents[1]
MAX_WAIT_MINUTES=int(os.getenv("TT_ORPHAN_MAX_WAIT_MINUTES","30"))
REPEAT_ALERT_HOURS=6

def read(name,default=None):
    try:return json.loads((ROOT/name).read_text(encoding="utf-8"))
    except (OSError,ValueError):
        if name=="telegram/lifecycle-baseline.json" and ROOT==Path(__file__).resolve().parents[1]:
            try:
                import subprocess
                result=subprocess.run(
                    ["git","show","origin/main:telegram/lifecycle-baseline.json"],
                    cwd=str(ROOT),capture_output=True,text=True,check=True,timeout=8)
                return json.loads(result.stdout)
            except (OSError,ValueError,subprocess.SubprocessError):
                print("TT_ORPHAN_BASELINE_NOT_READABLE",flush=True)
        return default

def when(value):
    try:
        result=datetime.fromisoformat(str(value or "").replace("Z","+00:00"))
        if result.tzinfo is None: result=result.replace(tzinfo=timezone.utc)
        return result.astimezone(timezone.utc)
    except (ValueError,TypeError):return None

def audit(project,now=None,root=None):
    global ROOT
    if root is not None:ROOT=Path(root)
    now=now or datetime.now(timezone.utc)
    trend=project=="ttendencias"
    delivery_path=("trends/telegram-image-deliveries.json" if trend
                   else "telegram/ttittulares-deliveries.json")
    doc=read(delivery_path,{"items":[]}) or {}
    checkpoint=read("telegram/lifecycle-baseline.json",{}) or {}
    reset=(checkpoint.get("project_state") or {}).get(project) or {}
    cutoff=when(checkpoint.get("activated_at"))
    prior_max_mid=int(reset.get("historic_max_message_id") or 0)
    protected_ids={str(x) for x in (reset.get("preserve_pending_ids") or [])}
    deliveries=[x for x in doc.get("items",[]) or []
                if not cutoff or int(x.get("telegram_message_id") or 0)>prior_max_mid]
    terminal={"deleted","published","dismissed","removed","delete_pending","delete_failed"}
    problems={}
    requests={}
    if trend:
        reqs=read("trends/requests.json",{"requests":[]}) or {}
        requests={str(x.get("id") or ""):x for x in reqs.get("requests",[])
                  if x.get("id")}
    else:
        status=read("ttittulares/status.json",{}) or {}
        problems={str(x.get("event_id") or ""):x
                  for x in status.get("problematic_items",[]) if x.get("event_id")}
        jobs={str(x.get("event_id") or ""):x
              for x in status.get("processing_items",[]) if x.get("event_id")}
        requests.update(jobs)
        requests.update(problems)
    latest={}
    grouped_final={}
    # If a later revision finalizes the exact same Telegram message, the
    # earlier provisional ledger row is superseded. A final on a different
    # message must NOT hide an orphaned provisional.
    final_message_keys=set()
    for row in deliveries:
        key=str(row.get("event_id") or "")
        if key and (key not in latest or when(row.get("updated_at") or row.get("delivered_at"))
                    and (when(latest[key].get("updated_at") or latest[key].get("delivered_at"))
                         or datetime.min.replace(tzinfo=timezone.utc))
                    < when(row.get("updated_at") or row.get("delivered_at"))):
            latest[key]=row
        # A final group card is the definitive Telegram delivery for members
        # that never had an individual provisional. Existing individual
        # provisionals are still audited above and must be edited in place.
        final_group=(str(row.get("status") or "").lower() in terminal or
                     (str(row.get("status") or "").lower()=="sent" and row.get("final") is True))
        if final_group:
            message_id=int(row.get("telegram_message_id") or 0)
            if key and message_id:
                final_message_keys.add((key,message_id))
            for member_id in row.get("group_member_ids") or []:
                member_id=str(member_id or "")
                if member_id:
                    grouped_final[member_id]=row
    issues=[]
    for row in deliveries:
        if str(row.get("status") or "").lower()!="sent" or row.get("final") is not False:
            continue
        start=when(row.get("delivered_at") or row.get("started_at"))
        if not start:continue
        elapsed=(now-start).total_seconds()/60
        event_id=str(row.get("event_id") or "")
        message_id=int(row.get("telegram_message_id") or 0)
        if event_id and message_id and (event_id,message_id) in final_message_keys:
            continue
        req=requests.get(event_id,{})
        editorial_state=str(req.get("status") or "").lower()
        ready=bool(editorial_state in {"explained","ready","grouped"})
        problem=problems.get(event_id,{})
        # A problem cannot disappear behind the 30-minute timer.
        if elapsed<MAX_WAIT_MINUTES and not ready and not problem:
            continue
        title=str(row.get("title") or row.get("name") or req.get("name") or event_id)
        reason=str(problem.get("problem_reason") or "").strip()
        if reason:reason="Bloqueo editorial: "+reason
        elif ready:reason="Explicación disponible pero Telegram sigue provisional"
        else:reason="No consta explicación definitiva"
        issues.append({"key":f"provisional:{event_id}:{int(row.get('telegram_message_id') or 0)}",
            "id":event_id,"message_id":row.get("telegram_message_id"),
            "title":title,"age_min":round(elapsed,1),"reason":reason})
    if trend:
        # Top 10 auto-queued and explicitly requested Top 11-30 must not
        # vanish from editorial tracking before a delivery is recorded.
        for event_id,req in requests.items():
            if str(req.get("status") or "").lower() not in {"preparing","update","ready","explained"}:
                continue
            rank=int(req.get("rank") or 0)
            manual=(req.get("auto_queued") is False)
            if rank>10 and not manual:continue
            started=when(req.get("requested_at") or req.get("explained_at"))
            if cutoff and event_id not in protected_ids and (
                    not started or started<=cutoff):
                continue
            # Work older than 12h is archive, not a fresh Telegram delivery.
            # The standalone provisional scan above still catches old open cards.
            age_minutes=(now-started).total_seconds()/60 if started else 0
            if not started or not (MAX_WAIT_MINUTES <= age_minutes <= 12*60):
                continue
            row=latest.get(event_id)
            if row is None:
                row=grouped_final.get(event_id)
            if row and (row.get("status") in terminal or
                        (row.get("status")=="sent" and row.get("final") is True)):
                continue
            if row and row.get("status")=="sent" and row.get("final") is False:
                continue # already covered by the provisional audit
            age=(now-started).total_seconds()/60
            issues.append({"key":"missing:"+event_id,"id":event_id,
                "title":str(req.get("name") or event_id),"age_min":round(age,1),
                "reason":"Solicitud editorial sin entrega definitiva en Telegram"})
    else:
        for event_id,req in requests.items():
            started=when(req.get("selected_at") or req.get("problematic_at"))
            if cutoff and event_id not in protected_ids and (
                    not started or started<=cutoff):
                continue
            # Work older than 12h is archive, not a fresh Telegram delivery.
            # The standalone provisional scan above still catches old open cards.
            age_minutes=(now-started).total_seconds()/60 if started else 0
            if not started or not (MAX_WAIT_MINUTES <= age_minutes <= 12*60):
                continue
            row=latest.get(event_id)
            if row and (row.get("status") in terminal or
                        (row.get("status")=="sent" and row.get("final") is True)):
                continue
            if row and row.get("status")=="sent" and row.get("final") is False:
                continue
            issues.append({"key":"missing:"+event_id,"id":event_id,
                "title":str(req.get("title") or event_id),
                "age_min":round((now-started).total_seconds()/60,1),
                "reason":str(req.get("problem_reason") or
                             "Seleccionada y sin explicación/entrega final")})
    seen=set()
    unique=[]
    for item in issues:
        if item["key"] not in seen:
            seen.add(item["key"])
            unique.append(item)
    unique.sort(key=lambda x:(-x["age_min"],x["key"]))
    return {"project":project,"checked_at":now.isoformat(),
            "verification":"Telegram API send/edit acknowledgements + persisted deliveries; bot API does not provide private chat history",
            "ledger_entries":len(deliveries),
            "baseline_at":checkpoint.get("activated_at"),
            "archived_before_message_id":prior_max_mid,
            "unresolved_count":len(unique),
            "unresolved":unique[:40]}

def persist_and_alert(project,report,token,chat):
    state_path=f"telegram/orphan-audit-{project}.json"
    prev=read(state_path,{}) or {}
    prev_alerts=prev.get("alerted") or {}
    now=when(report["checked_at"]) or datetime.now(timezone.utc)
    new_alerts={}
    urgent=[]
    send_notices=os.getenv("TT_ORPHAN_CHAT_NOTIFICATIONS","0")=="1"
    for item in report["unresolved"]:
        signature=hashlib.sha256((item["key"]+"|"+item["reason"]).encode()).hexdigest()[:18]
        old=prev_alerts.get(item["key"]) or {}
        last=when(old.get("notified_at"))
        should_alert=(old.get("signature")!=signature or not last or
                      (now-last).total_seconds()>=REPEAT_ALERT_HOURS*3600)
        if should_alert and send_notices:urgent.append(item)
        new_alerts[item["key"]]={"signature":signature,
            "notified_at":(now.isoformat() if should_alert and send_notices
                           else old.get("notified_at"))}
    if not send_notices and report["unresolved"]:
        print("TT_ORPHAN_INDEX_ONLY",project,
              "unresolved="+str(report["unresolved_count"]),flush=True)
    if urgent:
        parts=[f"⚠️ {project.upper()} · {len(urgent)} aviso(s) sin resolver.",
               "No se ha borrado ninguna tarjeta automáticamente."]
        for item in urgent[:5]:
            title=item["title"][:110]
            reason=item["reason"].replace("\n"," ").strip()[:220]
            parts.append(f"• {title} (mensaje {item.get('message_id') or 'sin envío'}, {item['age_min']} min): {reason}")
        if len(urgent)>5:parts.append(f"Y {len(urgent)-5} casos más en el informe de auditoría.")
        parts.append("La noticia o tendencia sigue pendiente de elaboración/actualización; requiere revisión editorial.")
        if not token or not chat:
            raise RuntimeError("Telegram alert credentials/chat missing; unresolved issues NOT reported")
        payload={"chat_id":str(chat),"text":"\n".join(parts)[:3900]}
        data=json.dumps(payload,ensure_ascii=False).encode()
        req=Request("https://api.telegram.org/bot"+token+"/sendMessage",
                    data=data,headers={"Content-Type":"application/json"})
        with urlopen(req,timeout=35) as response:result=json.load(response)
        if not result.get("ok"):
            raise RuntimeError("Telegram rejected orphan alert")
        print("TT_ORPHAN_TELEGRAM_ALERT_SENT",project,len(urgent),flush=True)
    report["alerted"]=new_alerts
    report["last_alert_count"]=len(urgent)
    path=ROOT/state_path
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print("TT_ORPHAN_AUDIT",project,"unresolved="+str(report["unresolved_count"]),
          "alerts="+str(len(urgent)),flush=True)

def selftest():
    import tempfile
    now=datetime(2026,10,12,16,35,tzinfo=timezone.utc)
    with tempfile.TemporaryDirectory() as d:
        root=Path(d)
        for prefix in ("telegram","ttittulares","trends"):(root/prefix).mkdir()
        (root/"telegram/ttittulares-deliveries.json").write_text(json.dumps({"items":[
            {"event_id":"sol","title":"Tensión en Sol","status":"sent","final":False,
             "telegram_message_id":3555,"delivered_at":"2026-10-12T14:11:00Z"},
            {"event_id":"closed","status":"deleted","final":True,"telegram_message_id":3550}]}))
        (root/"ttittulares/status.json").write_text(json.dumps({"problematic_items":[
            {"event_id":"sol","title":"Tensión en Sol","problem_reason":"Falta revisión"}]}))
        report=audit("ttittulares",now,root)
        assert report["unresolved_count"]==1,report
        assert report["unresolved"][0]["message_id"]==3555
        # A new revision that finalizes the very same Telegram message
        # closes the older provisional row without masking other messages.
        (root/"telegram/ttittulares-deliveries.json").write_text(json.dumps({"items":[
            {"event_id":"sol","revision":1,"title":"Tensión en Sol","status":"sent","final":False,
             "telegram_message_id":3555,"delivered_at":"2026-10-12T14:11:00Z"},
            {"event_id":"sol","revision":2,"title":"Tensión en Sol","status":"sent","final":True,
             "telegram_message_id":3555,"delivered_at":"2026-10-12T14:11:00Z",
             "updated_at":"2026-10-12T16:30:00Z"}]}))
        assert audit("ttittulares",now,root)["unresolved_count"]==0
        (root/"trends/telegram-image-deliveries.json").write_text(json.dumps({"items":[
            {"event_id":"j","status":"sent","final":False,"telegram_message_id":714,
             "delivered_at":"2026-10-12T14:18:00Z"}]}))
        (root/"trends/requests.json").write_text(json.dumps({"requests":[
            {"id":"j","rank":5,"name":"Jagoba","status":"explained",
             "requested_at":"2026-10-12T14:12:00Z"}]}))
        report=audit("ttendencias",now,root)
        assert report["unresolved_count"]==1,report
        (root/"trends/telegram-image-deliveries.json").write_text(json.dumps({"items":[
            {"event_id":"j","status":"sent","final":True,"telegram_message_id":714,
             "delivered_at":"2026-10-12T14:18:00Z"}]}))
        assert audit("ttendencias",now,root)["unresolved_count"]==0
        # Post-reset: historic missing requests and delivered messages are
        # finished, while protected pending requests MUST remain actionable.
        baseline={"activated_at":"2026-10-12T15:25:23Z",
                  "project_state":{"ttendencias":{
                      "historic_max_message_id":714,
                      "preserve_pending_ids":["new-trend"]},
                    "ttittulares":{"historic_max_message_id":3555,
                                   "preserve_pending_ids":[]}}}
        (root/"telegram/lifecycle-baseline.json").write_text(json.dumps(baseline))
        (root/"trends/requests.json").write_text(json.dumps({"requests":[
            {"id":"historic","rank":1,"name":"Historic","status":"preparing",
             "requested_at":"2026-10-12T14:12:00Z"},
            {"id":"new-trend","rank":8,"name":"New","status":"preparing",
             "requested_at":"2026-10-12T15:23:00Z"}]}))
        assert [v["id"] for v in audit("ttendencias",now,root)["unresolved"]]==["new-trend"]
        assert audit("ttittulares",now,root)["unresolved_count"]==0
    print("TT_ORPHAN_AUDIT_SELFTEST_OK")

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("project",choices=["ttendencias","ttittulares","selftest"])
    args=parser.parse_args()
    if args.project=="selftest":selftest()
    else:
        report=audit(args.project)
        if args.project=="ttendencias":
            token=os.getenv("TTENDENCIAS_BOT_TOKEN","")
            chat=os.getenv("TTENDENCIAS_CHAT_ID","") or (read("trends/telegram-bot-state.json",{}) or {}).get("chat_id")
        else:
            token=os.getenv("TELEGRAM_BOT_TOKEN","")
            chat=os.getenv("TELEGRAM_CHAT_ID","")
        persist_and_alert(args.project,report,token,chat)
