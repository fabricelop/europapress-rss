#!/usr/bin/env python3
"""Bounded, idempotent, non-editorial auto-repair for both private TT bots.

Does NOT delete messages, invent content, publish, or mark a row final.
Only runs existing GitHub workflows, checks authoritative ledgers/queues,
and escalates genuinely unfixable editorial work with a copyable prompt.
"""
import json
import os
import hashlib
import uuid
import sys
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone, timedelta
from urllib.parse import quote

ROOT=Path(__file__).resolve().parents[1]
REPO="fabricelop/europapress-rss"
STATE="telegram/tt-autoheal-state.json"
PC_RECOVERY="telegram/tt-local-recovery-request.json"
CONFIG={
    "ttittulares":{
        "queue":"ttittulares/editorial-queue.json",
        "ledger":"telegram/ttittulares-deliveries.json",
        "index":"telegram/pinned-index-ttittulares.json",
        "send":"send-ttittulares-ready-telegram.yml",
        "chat":"TELEGRAM_CHAT_ID",
        "token":"TELEGRAM_BOT_TOKEN",
        "watermark":3566},
    "ttendencias":{
        "queue":"trends/editorial-queue.json",
        "ledger":"trends/telegram-image-deliveries.json",
        "index":"telegram/pinned-index-ttendencias.json",
        "send":"send-ttendencias-explained-telegram.yml",
        "chat":"TTENDENCIAS_CHAT_ID",
        "token":"TTENDENCIAS_BOT_TOKEN",
        "watermark":719},
}
ACTIVE={"preparing","update","processing","ready","explained","in_progress"}
TERMINAL={"deleted","published","dismissed","removed","delete_pending","delete_failed"}
COOLDOWN=15*60
ESCALATE=20*60

def read(name,default):
    try:return json.loads((ROOT/name).read_text(encoding="utf-8"))
    except (OSError,ValueError):return default

def save(name,doc):
    target=ROOT/name
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(json.dumps(doc,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def timeof(value):
    try:
        d=datetime.fromisoformat(str(value or "").replace("Z","+00:00"))
        return d.replace(tzinfo=timezone.utc) if d.tzinfo is None else d.astimezone(timezone.utc)
    except (ValueError,TypeError):return None

def age(now,when):
    v=timeof(when)
    return (now-v).total_seconds() if v else 0.0

def problems(project,now):
    conf=CONFIG[project]
    checkpoint=read("telegram/lifecycle-baseline.json",{})
    cut=timeof(checkpoint.get("activated_at"))
    cutoff=(checkpoint.get("project_state") or {}).get(project,{})
    watermark=int(cutoff.get("historic_max_message_id") or conf["watermark"])
    keep=set(str(x) for x in cutoff.get("preserve_pending_ids",[]))
    queue=read(conf["queue"],{"items":[]})
    ledger=read(conf["ledger"],{"items":[]})
    idx=read(conf["index"],{})
    if not isinstance(queue.get("items"),list) or not isinstance(ledger.get("items"),list):
        raise RuntimeError("Editorial queue/delivery ledger invalid "+project)
    live={}
    closed=set()
    for x in ledger["items"]:
        eid=str(x.get("event_id") or "")
        mid=int(x.get("telegram_message_id") or 0)
        if mid<=watermark or not eid:continue
        st=str(x.get("status") or "").lower()
        if st in TERMINAL:closed.add(eid)
        if st=="sent" and mid>0:
            if eid not in live or int(live[eid].get("telegram_message_id") or 0)<mid:
                live[eid]=x
    q={}
    for x in queue["items"]:
        eid=str(x.get("id") or x.get("event_id") or "")
        if not eid or eid in closed or str(x.get("status") or "").lower() not in ACTIVE:
            continue
        created=x.get("requested_at") or x.get("selected_at")
        if cut and eid not in keep:
            entered=timeof(created)
            if not entered or entered<=cut:continue
        q[eid]=x
    result=[]
    for eid,x in q.items():
        row=live.get(eid)
        started=x.get("requested_at") or x.get("selected_at")
        age_s=age(now,started)
        if age_s<0:continue
        st=str(x.get("status") or "").lower()
        is_final=st=="explained" or bool(x.get("editorial_verified") and x.get("explanation"))
        if row is None and age_s>=120:
            # A stalled editorial request is NOT fixed by dispatching Telegram.
            editorial_stuck=(project=="ttendencias" and
                             st in {"preparing","update"} and age_s>=ESCALATE)
            result.append({"kind":"editorial_overdue" if editorial_stuck else "missing_delivery",
                           "id":eid,
                           "title":str(x.get("name") or x.get("title") or eid)[:100],
                           "seconds":int(age_s),
                           "workflow":None if editorial_stuck else conf["send"]})
        elif row and row.get("final") is not True and is_final and age_s>=120:
            result.append({"kind":"unfinished_ready","id":eid,
                           "title":str(x.get("name") or x.get("title") or eid)[:100],
                           "seconds":int(age_s),"workflow":conf["send"]})
        elif row and age_s>=ESCALATE and (
                row.get("final") is not True or
                (project=="ttendencias" and st in {"preparing","update"})):
            # A final Telegram ack cannot complete a pending editorial queue.
            # No background LLM/editorial inference. Escalate for research.
            result.append({"kind":"editorial_overdue","id":eid,
                           "title":str(x.get("name") or x.get("title") or eid)[:100],
                           "seconds":int(age_s),"workflow":None})
    # TTendencias also persists current jobs in requests.json (2 MB+).
    # The short editorial queue can be EMPTY while a current manual/top-10
    # request or the ORIGINAL Telegram provisional remains unfinished.
    # Check these independently before claiming "0 incidents".
    if project=="ttendencias":
        request_doc=read("trends/requests.json",{"requests":[]})
        explained_doc=read("trends/telegram-manual-explained.json",{"items":[]})
        if (not isinstance(request_doc.get("requests"),list) or
                not isinstance(explained_doc.get("items"),list)):
            raise RuntimeError("TTendencias request/explained catalog invalid")
        # Include terminal revisions when selecting the latest request: an older
        # preparing revision must never override a later user deletion.
        latest_req={}
        for req in request_doc["requests"]:
            rid=str(req.get("id") or "")
            if not rid:continue
            prev=latest_req.get(rid)
            if prev is None or int(req.get("revision") or 0)>=int(prev.get("revision") or 0):
                latest_req[rid]=req
        explained_by_revision={}
        for item in explained_doc["items"]:
            if str(item.get("status") or "").lower()=="explained":
                key=(str(item.get("id") or ""),int(item.get("revision") or 0))
                explained_by_revision[key]=item
        for eid,req in latest_req.items():
            if eid in q or eid in closed:continue
            status=str(req.get("status") or "").lower()
            if status not in {"preparing","update","ready","explained"}:continue
            if req.get("auto_queued") is True and int(req.get("rank") or 0)>10:
                continue
            began=req.get("requested_at") or req.get("anticipated_at")
            secs=age(now,began)
            # Keep post-baseline editorial jobs pending beyond 24h. Only
            # completed delivery repairs have a 24h safety window.
            if not began or secs<120:continue
            if status in {"ready","explained"} and secs>24*3600:continue
            if cut and eid not in keep:
                t=timeof(began)
                if not t or t<=cut:continue
            row=live.get(eid)
            title=str(req.get("name") or eid)[:100]
            revision=int(req.get("revision") or 0)
            verified_row=explained_by_revision.get((eid,revision))
            verified=bool(status=="explained" and verified_row and
                          all(req.get(field)==verified_row.get(field)
                              for field in ("id","revision","explanation",
                                            "closer_text","explained_at")) and
                          str(req.get("explanation") or "").strip())
            if verified and row and row.get("final") is True:
                continue
            if verified:
                kind="unfinished_ready" if row else "missing_delivery"
                result.append({"kind":kind,"id":eid,
                               "title":title,"seconds":int(secs),
                               "workflow":conf["send"]})
            elif secs>=ESCALATE:
                # No verified matched text: never close editorial work through
                # a Telegram delivery (even when the ledger says final:true).
                result.append({"kind":"editorial_overdue","id":eid,
                               "title":title,"seconds":int(secs),"workflow":None})
            elif row is None:
                # A provisional card is harmless before the editorial deadline.
                result.append({"kind":"missing_delivery","id":eid,
                               "title":title,"seconds":int(secs),
                               "workflow":conf["send"]})
    # A provisional row might have disappeared from the queue; preserve it.
    already={r["id"] for r in result if r["kind"] in {
        "unfinished_ready","editorial_overdue","missing_delivery","orphan_provisional"}}
    for eid,row in live.items():
        if eid in q or eid in closed or eid in already or row.get("final") is True:continue
        entered=row.get("started_at") or row.get("delivered_at")
        if age(now,entered)<ESCALATE:continue
        result.append({"kind":"orphan_provisional","id":eid,
                       "title":str(row.get("title") or eid)[:100],
                       "seconds":int(age(now,entered)),"workflow":None})
    checked=idx.get("checked_at")
    index_age=age(now,checked)
    if checked and index_age>8*60:
        result.append({"kind":"stale_index","id":"pinned-index","title":"Índice fijado sin actualizar",
                       "seconds":int(index_age),"workflow":"telegram-pinned-index.yml"})
    return result

def prompt(project,issues):
    few=", ".join(x["id"] for x in issues[:3])
    return ("Autocorrige "+project+" en fabricelop/europapress-rss: "
            "revisa telegram/tt-autoheal-state.json, colas, entregas y "
            "GitHub Actions. Incidencias: "+few+
            ". Repara en main y verifica Telegram; no borres ni inventes.")

def github_dispatch(workflow):
    token=os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
    if not token:raise RuntimeError("GH_TOKEN missing")
    url=f"https://api.github.com/repos/{REPO}/actions/workflows/{workflow}/dispatches"
    req=urllib.request.Request(url,data=b'{"ref":"main"}',method="POST",headers={
        "Authorization":"Bearer "+token,
        "Accept":"application/vnd.github+json",
        "Content-Type":"application/json","User-Agent":"TT-autorepair"})
    try:
        with urllib.request.urlopen(req,timeout=25) as r:
            if r.status!=204:raise RuntimeError("GitHub refused dispatch")
    except urllib.error.HTTPError as exc:
        desc=exc.read(400).decode(errors="replace")
        raise RuntimeError("GitHub dispatch HTTP "+str(exc.code)+" "+desc) from exc
    return True

def telegram(token,method,body):
    req=urllib.request.Request(f"https://api.telegram.org/bot{token}/{method}",
        data=json.dumps(body,ensure_ascii=False).encode(),method="POST",
        headers={"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req,timeout=25) as r:
            data=json.load(r)
    except urllib.error.HTTPError as exc:
        body=exc.read(400).decode(errors="replace")
        raise RuntimeError("Telegram "+method+" HTTP "+str(exc.code)+" "+body) from exc
    if not data.get("ok"):raise RuntimeError("Telegram "+method+" returned false")
    return data.get("result")

def notice(project,issues,prev,now,send=telegram):
    conf=CONFIG[project]
    token=os.getenv(conf["token"],"")
    chat=os.getenv(conf["chat"],"")
    if not token or not chat:
        raise RuntimeError("No private Telegram credentials for "+project)
    msg=("⚠️ AUTOCORRECCIÓN · "+project+"\n"
         "Los reintentos técnicos no han resuelto todas las entradas.\n"
         +"\n".join("• "+x["title"]+" ("+x["kind"]+")" for x in issues[:6])+
         "\nEl botón Autocorregir lanza otra revisión técnica; "
         "la orden para ChatGPT requiere pegarla y enviarla tú.")
    button="tt:heal" if project=="ttittulares" else "tx:heal"
    prompt_text=prompt(project,issues)[:256]
    markup={"inline_keyboard":[
        [{"text":"🔧 Autocorregir ahora","callback_data":button}],
        [{"text":"📋 Orden para ChatGPT","copy_text":{"text":prompt_text}},
         {"text":"Abrir ChatGPT","url":"https://chatgpt.com/"}]
    ]}
    old=int(prev.get("alert_message_id") or 0)
    if old:
        try:
            send(token,"editMessageText",{"chat_id":chat,"message_id":old,
                "text":msg,"reply_markup":markup,"link_preview_options":{"is_disabled":True}})
            return old
        except Exception:pass
    result=send(token,"sendMessage",{"chat_id":chat,"text":msg,
                 "reply_markup":markup,"disable_notification":True})
    return int(result.get("message_id") or 0)

def request_safe_pc_recovery(now,editorial_ids=None):
    """Durable signal for the local watchdog, never a remote shell command.

    A private Telegram button triggers a workflow. The PC checks this marker
    only when connected and performs safe Chrome/ChatGPT tab recovery locally.
    """
    signal={
        "version":1,
        "request_id":uuid.uuid4().hex,
        "requested_at":now.isoformat(),
        "projects":["ttittulares","ttendencias"],
        "action":"recover_chat_tab_if_missing",
        "reason":"telegram_manual_autoheal"
    }
    ids=[str(x) for x in (editorial_ids or []) if str(x)]
    if ids:
        # Data only: the Windows watchdog may invoke the existing local
        # editorial task, after checking these revisions are still pending.
        # No arbitrary shell command or generated explanation is transported.
        signal["editorial_retry"]={"ttendencias":list(dict.fromkeys(ids))[:25]}
    save(PC_RECOVERY,signal)
    return True

def run(now=None,force=False,dispatch=github_dispatch,send=telegram):
    now=now or datetime.now(timezone.utc)
    state=read(STATE,{"version":1,"projects":{},"attempts":{}})
    attempts=state.setdefault("attempts",{})
    outcomes={}
    if force:
        # Both private Autocorregir buttons request safe Chrome recovery.
        # For stuck TTendencias text, ask the LOCAL scheduled ChatGPT editorial
        # launcher to run once; GitHub image repair cannot write explanations.
        overdue=[x["id"] for x in problems("ttendencias",now)
                 if x["kind"]=="editorial_overdue"]
        request_safe_pc_recovery(now,overdue)
    for project in CONFIG:
        issues=problems(project,now)
        actions=sorted({x["workflow"] for x in issues if x.get("workflow")})
        # Workflows on workflow_run are the primary, token-free dispatch.
        # Leave direct calls opt-in as recovery if an approved token exists.
        direct=os.getenv("TT_AUTOHEAL_DIRECT_DISPATCH","0")=="1"
        if not direct:
            actions=[]
        triggered=[]
        errors=[]
        for wf in actions:
            previous=timeof(attempts.get(project+":"+wf))
            if not force and previous and (now-previous).total_seconds()<COOLDOWN:
                continue
            try:
                dispatch(wf)
                triggered.append(wf)
                attempts[project+":"+wf]=now.isoformat()
            except Exception as e:
                errors.append(wf+" "+str(e)[:300])
        prev=state.setdefault("projects",{}).get(project,{})
        summary="|".join(sorted(x["kind"]+":"+x["id"] for x in issues))
        signature=hashlib.sha256(summary.encode()).hexdigest()
        human=[x for x in issues if (x["seconds"]>=ESCALATE and
               x["kind"] in {"orphan_provisional","editorial_overdue","missing_delivery","unfinished_ready"})]
        # Do not spam: ONE editable warning per project, at most one new
        # notification every 60 minutes for the same unresolved signature.
        last=timeof(prev.get("last_alert_at"))
        eligible=bool(human and os.getenv("TT_AUTOHEAL_SEND_ALERTS","0")=="1"
            and (signature!=prev.get("last_alert_signature")
            or not last or (now-last).total_seconds()>=3600))
        # Silent by design: diagnostics live in GitHub and the fixed index.
        # Never create any standalone maintenance notice, regardless of env.
        eligible=False
        if eligible:
            try:
                mid=notice(project,human,prev,now,send=send)
                prev["alert_message_id"]=mid
                prev["last_alert_at"]=now.isoformat()
                prev["last_alert_signature"]=signature
            except Exception as e:
                errors.append("telegram_alert "+str(e)[:300])
        prev.update({"checked_at":now.isoformat(),"issue_count":len(issues),
                     "repair_via_workflow_run":not direct,
                     "escalation_required":len(human),
                     "issues":issues[:30],"actions_started":triggered,
                     "repair_errors":errors,"open_signature":signature})
        state["projects"][project]=prev
        outcomes[project]={"issues":len(issues),"dispatched":triggered,
                           "errors":errors}
    state["checked_at"]=now.isoformat()
    save(STATE,state)
    print("TT_AUTOHEAL "+json.dumps(outcomes,ensure_ascii=False),flush=True)
    return outcomes

def selftest():
    import tempfile
    global ROOT
    original=ROOT
    with tempfile.TemporaryDirectory() as td:
        ROOT=Path(td)
        try:
            now=datetime(2026,10,12,18,0,tzinfo=timezone.utc)
            save("telegram/lifecycle-baseline.json",{"activated_at":"2026-10-12T15:25:23Z",
                "project_state":{"ttittulares":{"historic_max_message_id":3566},
                                  "ttendencias":{"historic_max_message_id":719}}})
            for p,c in CONFIG.items():
                save(c["queue"],{"items":[{"id":p+"-1","name":"Noticia real",
                   "status":"preparing","requested_at":"2026-10-12T17:56:00Z"}]})
                save(c["ledger"],{"items":[]})
                save(c["index"],{"checked_at":"2026-10-12T17:40:00Z"})
            calls=[]
            def fake(w):calls.append(w)
            os.environ["TT_AUTOHEAL_DIRECT_DISPATCH"]="1"
            a=run(now,False,dispatch=fake)
            assert len(calls)==4 and a["ttittulares"]["issues"]==2
            assert len(a["ttendencias"]["dispatched"])==2
            calls.clear()
            run(now+timedelta(minutes=4),False,dispatch=fake)
            assert calls==[]
            assert read(STATE,{})["projects"]["ttendencias"]["issue_count"]==2
            # Image-status panels remain repairable, but alerts are retired.
            save(CONFIG["ttendencias"]["index"],{
                "checked_at":"2026-10-12T17:58:00Z",
                "green_notifications_initialized":True,
                "green_notifier_checked_at":"2026-10-12T17:30:00Z"})
            assert not any(x["kind"]=="stale_green_notifier" for x in problems("ttendencias",now))
            # Final Telegram acknowledgement must not mask a stalled queue.
            save("trends/editorial-queue.json",{"items":[{
                "id":"still-in-queue","name":"Investigación sin cerrar",
                "status":"preparing","requested_at":"2026-10-12T17:30:00Z"}]})
            save("trends/telegram-image-deliveries.json",{"items":[{
                "event_id":"still-in-queue","telegram_message_id":722,
                "status":"sent","final":True,"started_at":"2026-10-12T17:30:00Z"}]})
            assert next(x for x in problems("ttendencias",now)
                        if x["id"]=="still-in-queue")["kind"]=="editorial_overdue"
            # A cleared compact editorial queue must not hide a stalled
            # TTendencias request or an existing provisional Telegram card.
            save("trends/editorial-queue.json",{"items":[]})
            save("trends/requests.json",{"requests":[
                {"id":"stalled-trend","name":"Tendencia pendiente",
                 "status":"preparing","rank":3,"auto_queued":True,
                 "requested_at":"2026-10-12T17:30:00Z"}]})
            save("trends/telegram-image-deliveries.json",{"items":[{
                "event_id":"stalled-trend","telegram_message_id":721,
                "status":"sent","final":False,"started_at":"2026-10-12T17:30:00Z"}]})
            issue=problems("ttendencias",now)
            assert sum(x["id"]=="stalled-trend" for x in issue)==1,issue
            assert next(x for x in issue if x["id"]=="stalled-trend")["kind"]=="editorial_overdue"
            # Verified copy changes the repair into a delivery retry, without
            # inventing an explanation or replacing the original Telegram ID.
            doc=read("trends/requests.json",{})
            doc["requests"][0].update(status="explained",
                explanation="Hecho comprobado en fuentes.",closer_text="",
                revision=0,explained_at="2026-10-12T17:40:00Z",
                editorial_verified=True)
            save("trends/requests.json",doc)
            save("trends/telegram-manual-explained.json",{"items":[{
                "id":"stalled-trend","revision":0,"status":"explained",
                "explanation":"Hecho comprobado en fuentes.","closer_text":"",
                "explained_at":"2026-10-12T17:40:00Z"}]})
            issue=problems("ttendencias",now)
            assert next(x for x in issue if x["id"]=="stalled-trend")["kind"]=="unfinished_ready"
            # A status flag alone cannot certify a missing or mismatched text.
            save("trends/telegram-manual-explained.json",{"items":[]})
            issue=problems("ttendencias",now)
            assert next(x for x in issue if x["id"]=="stalled-trend")["kind"]=="editorial_overdue"
            save("trends/telegram-manual-explained.json",{"items":[{
                "id":"stalled-trend","revision":0,"status":"explained",
                "explanation":"Hecho comprobado en fuentes.","closer_text":"",
                "explained_at":"2026-10-12T17:40:00Z"}]})
            # A completed Telegram ack with an unverified request is still blocked.
            doc["requests"][0]["status"]="preparing"
            save("trends/requests.json",doc)
            delivery=read("trends/telegram-image-deliveries.json",{})
            delivery["items"][0]["final"]=True
            save("trends/telegram-image-deliveries.json",delivery)
            assert next(x for x in problems("ttendencias",now)
                        if x["id"]=="stalled-trend")["kind"]=="editorial_overdue"
            doc["requests"][0]["status"]="explained"
            save("trends/requests.json",doc)
            assert not any(x["id"]=="stalled-trend" for x in problems("ttendencias",now))
            delivery["items"][0]["final"]=False
            save("trends/telegram-image-deliveries.json",delivery)
            # Pending editorial work cannot expire after the old 24h window.
            old={"id":"very-old-pending","name":"Pendiente desde hace dos días",
                 "revision":0,"rank":2,"status":"preparing",
                 "requested_at":"2026-10-12T17:30:00Z"}
            save("trends/requests.json",{"requests":[old]})
            aged=problems("ttendencias",now+timedelta(days=2))
            assert next(x for x in aged if x["id"]=="very-old-pending")["kind"]=="editorial_overdue"
            # A later terminal request does not resurrect the prior revision.
            save("trends/requests.json",{"requests":[old,{
                **old,"revision":1,"status":"deleted"}]})
            assert not any(x["id"]=="very-old-pending"
                           for x in problems("ttendencias",now+timedelta(days=2)))
            save("trends/requests.json",doc)
            # User deletion is terminal even when requests.json is stale.
            delivery=read("trends/telegram-image-deliveries.json",{})
            delivery["items"][0]["status"]="deleted"
            save("trends/telegram-image-deliveries.json",delivery)
            assert not any(x["id"]=="stalled-trend" for x in problems("ttendencias",now))
            assert not (ROOT/PC_RECOVERY).exists(), "scheduled autoheal must not signal PC"
            assert request_safe_pc_recovery(now+timedelta(minutes=6))
            first=read(PC_RECOVERY,{})
            assert first["action"]=="recover_chat_tab_if_missing"
            assert first["projects"]==["ttittulares","ttendencias"]
            assert first["request_id"] and first["requested_at"]
            request_safe_pc_recovery(now+timedelta(minutes=7),["trend001","trend002"])
            second=read(PC_RECOVERY,{})
            assert second["request_id"]!=first["request_id"], "each manual press needs a distinct request"
            assert second["editorial_retry"]["ttendencias"]==["trend001","trend002"]
            assert "editorial_retry" not in first
            print("TT_AUTOHEAL_SELFTEST_OK")
        finally:
            os.environ.pop("TT_AUTOHEAL_DIRECT_DISPATCH",None)
            ROOT=original

if __name__=="__main__":
    if "selftest" in sys.argv:selftest()
    else:run(force="--force" in sys.argv)
