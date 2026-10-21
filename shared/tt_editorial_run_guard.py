#!/usr/bin/env python3
"""Editorial execution SLA and nonduplicating self-healing for TT bots.

The Telegram senders cannot write verified editorial copy. Request execution
through the EXISTING Windows/ChatGPT editorial control channels, then require
an independent RUNNING/DONE acknowledgement. Never claim a request is a run.
"""
import base64
import hashlib
import json
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
REPO="fabricelop/europapress-rss"
REPORT="telegram/editorial-run-guard.json"
START_AFTER=timedelta(minutes=5)
RETRY_AFTER=timedelta(minutes=15)
ACTIVE_TTL=timedelta(minutes=12)
RECENT_DONE_GRACE=timedelta(minutes=5)
MAX_RETRIES=3
TERMINAL={"deleted","dismissed","published","removed","delete_pending","delete_failed"}
CONFIG={
    "ttittulares":{
        "queue":"ttittulares/editorial-queue.json",
        "ledger":"telegram/ttittulares-deliveries.json",
        "cutoff":3566,
        "branch":"control/ttittulares-run-trigger-v2",
        "control":"ttittulares/run-now-trigger.json",
        "issue":2,
        "trace":"TTITTULARES_RUNTRACE_V1",
        "runtime":None,"executor":"pc_chat_ttittulares_dedicated",
        "arg":"titulares"},
    "ttendencias":{
        "queue":"trends/editorial-queue.json",
        "ledger":"trends/telegram-image-deliveries.json",
        "cutoff":719,
        "branch":"control/ttendencias-run-trigger",
        "control":"trends/run-now-trigger.json",
        "issue":7,
        "trace":"TTENDENCIAS_RUNTRACE_V1",
        "runtime":"trends/editorial-runtime.json",
        "executor":"pc_chat_ttendencias_dedicated",
        "arg":"tendencias"},
}

def load(file,default=None):
    try:return json.loads((ROOT/file).read_text(encoding="utf8"))
    except (OSError,ValueError):return default if default is not None else {}

def save(file,doc):
    p=ROOT/file;p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(doc,ensure_ascii=False,indent=2)+"\n",encoding="utf8")

def moment(s):
    try:
        d=datetime.fromisoformat(str(s or "").replace("Z","+00:00"))
        return d.replace(tzinfo=timezone.utc) if d.tzinfo is None else d.astimezone(timezone.utc)
    except (ValueError,TypeError):return None

def api(path,method="GET",payload=None,branch=None):
    token=os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
    if not token:raise RuntimeError("GITHUB_TOKEN_NOT_CONFIGURED")
    suffix=("?ref="+urllib.parse.quote(branch,safe="")) if branch else ""
    url="https://api.github.com/repos/"+REPO+"/"+path+suffix
    headers={"Authorization":"Bearer "+token,"Accept":"application/vnd.github+json",
             "X-GitHub-Api-Version":"2022-11-28",
             "User-Agent":"tt-editorial-run-guard"}
    data=json.dumps(payload).encode() if payload is not None else None
    if data is not None:headers["Content-Type"]="application/json"
    req=urllib.request.Request(url,data=data,headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=25) as resp:
            body=resp.read()
        return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        raise RuntimeError("GITHUB_HTTP_"+str(exc.code)+" "+exc.read(220).decode(errors="replace")) from exc

def latest_trace(project):
    cfg=CONFIG[project]
    issue=api("issues/"+str(cfg["issue"]))
    count=int(issue.get("comments") or 0)
    if not count:return {}
    # Get only the last page; a stream of old outbox comments must not
    # make us believe the editor is RUNNING today.
    page=max(1,(count-1)//20+1)
    comments=api("issues/"+str(cfg["issue"])+"/comments?per_page=20&page="+str(page))
    for item in reversed(comments):
        body=str(item.get("body") or "")
        if not body.startswith(cfg["trace"]+"\n"):continue
        try:
            trace=json.loads(body.split("\n",1)[1])
        except ValueError:continue
        if not isinstance(trace,dict):continue
        trace_time=moment(trace.get("updated_at") or trace.get("finished_at") or item.get("created_at"))
        if trace_time:return {"id":trace.get("run_id"),"status":str(trace.get("status") or ""),
           "started_at":trace.get("started_at"),"updated_at":trace_time.isoformat(),
           "finished_at":trace.get("finished_at"),"source":"github_pr_trace"}
    return {}

def known_run(project):
    trace=latest_trace(project)
    runtime_file=CONFIG[project].get("runtime")
    if runtime_file:
        doc=load(runtime_file,{})
        r=doc.get("last_run") or {}
        date=moment(r.get("updated_at") or doc.get("updated_at"))
        if date and (not moment(trace.get("updated_at")) or date>moment(trace.get("updated_at"))):
            trace={"id":r.get("run_id") or doc.get("run_id"),
                   "status":r.get("status") or doc.get("status"),
                   "started_at":r.get("started_at"),
                   "updated_at":date.isoformat(),
                   "finished_at":r.get("finished_at") or doc.get("last_completed_at"),
                   "source":"editorial_runtime"}
    return trace

def pending(project):
    cfg=CONFIG[project]
    q=load(cfg["queue"],{"items":[]}).get("items") or []
    d=load(cfg["ledger"],{"items":[]}).get("items") or []
    checkpoint=load("telegram/lifecycle-baseline.json",{})
    ps=(checkpoint.get("project_state") or {}).get(project,{})
    watermark=int(ps.get("historic_max_message_id") or cfg["cutoff"])
    cutoff=moment(checkpoint.get("activated_at"))
    protected={str(x) for x in ps.get("preserve_pending_ids",[])}
    by_id={}
    closed=set()
    finalized=set()
    for entry in d:
        eid=str(entry.get("event_id") or "")
        mid=int(entry.get("telegram_message_id") or 0)
        if mid<=watermark or not eid:continue
        state=str(entry.get("status") or "").lower()
        if state in TERMINAL:closed.add(eid)
        if state=="sent" and entry.get("final") is True:finalized.add(eid)
        if state=="sent" and entry.get("final") is False:
            by_id[eid]={"id":eid,
              "start":entry.get("started_at") or entry.get("delivered_at"),
              "title":entry.get("name") or entry.get("title") or eid,
              "reason":"telegram_provisional"}
    extra=load("ttittulares/status.json",{}) if project=="ttittulares" else load("trends/requests.json",{})
    if project=="ttittulares":
        q=list(q)+[dict(x,status="processing") for x in extra.get("processing_items",[])]
    else:
        q=list(q)+[x for x in extra.get("requests",[]) if
                    str(x.get("status") or "").lower() in {"preparing","update","ready"}]
    for row in q:
        eid=str(row.get("id") or row.get("event_id") or "")
        status=str(row.get("status") or "").lower()
        if not eid or eid in closed or eid in finalized or status not in {
                "processing","preparing","update","ready","in_progress","explained"}:
            continue
        at=row.get("selected_at") or row.get("requested_at")
        started=moment(at)
        if cutoff and eid not in protected and (not started or started<=cutoff):continue
        if eid not in by_id:
            by_id[eid]={"id":eid,"start":at,
              "title":row.get("name") or row.get("title") or eid,
              "reason":"app_awaiting_editorial"}
    # An empty queue can conceal an unresolved older provisional. No omission.
    for eid in closed|finalized:by_id.pop(eid,None)
    return sorted(by_id.values(),key=lambda x:(moment(x.get("start")) or datetime.max.replace(tzinfo=timezone.utc)))

def evaluate(project,now,previous,command=None,run=None):
    rows=pending(project)
    out={"project":project,"checked_at":now.isoformat(),"pending_count":len(rows),
         "pending_ids":[x["id"] for x in rows[:35]],
         "oldest_at":(min((x["start"] for x in rows if x.get("start")),default=None)),
         "latest_run":run or {},"control_command":(command or {}).get("command_id"),
         "last_command_at":(command or {}).get("requested_at"),
         "status":"no_work","should_dispatch":False}
    if not rows:return out
    # A global RUN/DONE alone is not a verified per-item completion.
    run_start=moment((run or {}).get("started_at"))
    out["item_execution"]=[{
        "id":x["id"],"entered_at":x.get("start"),
        "should_start_by":(moment(x.get("start"))+START_AFTER).isoformat() if moment(x.get("start")) else None,
        "global_run_after_entry":bool(run_start and moment(x.get("start")) and run_start>=moment(x.get("start"))),
        "final_telegram_delivery_confirmed":False
        } for x in rows[:35]]
    oldest_candidates=[moment(x.get("start")) for x in rows]
    oldest_candidates=[x for x in oldest_candidates if x is not None]
    oldest=min(oldest_candidates) if oldest_candidates else None
    if not oldest:
        out["status"]="missing_event_timestamp"
        return out
    key=hashlib.sha256("|".join(sorted(x["id"] for x in rows)).encode()).hexdigest()[:16]
    out["backlog_signature"]=key
    out["expected_start_by"]=(oldest+START_AFTER).isoformat()
    out["attempts"]=(int(previous.get("attempts") or 0)
                     if previous.get("backlog_signature")==key else 0)
    seen_start=moment((run or {}).get("started_at"))
    if seen_start and seen_start>=oldest:
        out["actual_start_at"]=seen_start.isoformat()
        out["start_delay_seconds"]=round((seen_start-oldest).total_seconds())
    if now-oldest<START_AFTER:
        out["status"]="within_start_window"
        return out
    run=run or {}
    run_upd=moment(run.get("updated_at"))
    run_status=str(run.get("status") or "").upper()
    if run_status in {"RUNNING","IN_PROGRESS","PROCESSING"} and run_upd and now-run_upd<ACTIVE_TTL:
        out["status"]="editor_running_acknowledged";return out
    run_finished=moment(run.get("finished_at"))
    if run_status.startswith("DONE") or run_status in {"SUCCESS","COMPLETED"}:
        if run_finished and now-run_finished<RECENT_DONE_GRACE:
            out["status"]="editorial_run_finished_delivery_unverified";return out
    active_control=moment((command or {}).get("requested_at"))
    if active_control and active_control>=oldest and now-active_control<RETRY_AFTER:
        out["status"]="dispatch_pending_ack" if not run_upd or run_upd<active_control else "awaiting_editorial_completion"
        return out
    previous_key=previous.get("backlog_signature")
    last=moment(previous.get("last_request_at"))
    tries=int(previous.get("attempts") or 0) if previous_key==key else 0
    out["backlog_signature"]=key
    out["attempts"]=tries
    if tries>=MAX_RETRIES:
        out["status"]="editorial_executor_unresponsive"
        return out
    if last and previous_key==key and now-last<RETRY_AFTER:
        out["status"]="retry_cooldown";return out
    out.update(status="editorial_run_overdue",should_dispatch=True)
    return out

def request(project,now,report):
    cfg=CONFIG[project]
    path="contents/"+cfg["control"]
    current=api(path,branch=cfg["branch"])
    old=json.loads(base64.b64decode(current["content"]).decode("utf8"))
    existing=moment(old.get("requested_at"))
    if existing and now-existing<RETRY_AFTER:
        return {"requested":False,"reason":"remote_recent_command",
                "command_id":old.get("command_id"),"requested_at":old.get("requested_at")}
    # Existing, supported Windows/ChatGPT handoff, never claim it executed.
    req_id=("tt" if project=="ttittulares" else "tr")+"-autoguard-"+str(int(now.timestamp()))
    payload={"version":2,"command_id":req_id,"requested_at":now.isoformat().replace("+00:00","Z"),
      "mode":"manual_pc_chat","executor":cfg["executor"],"project":project,
      "launcher_arg":cfg["arg"],"task":"editorial","auto_image_followup":False,
      "source":"tt_autoheal_editorial_watchdog",
      "reason":"editorial_not_started_in_time","pending_ids":report["pending_ids"][:30]}
    data=base64.b64encode((json.dumps(payload,ensure_ascii=False,indent=2)+"\n").encode()).decode()
    api(path,method="PUT",payload={"branch":cfg["branch"],"sha":current["sha"],
        "message":"TT editorial watchdog: pedir elaboración atrasada "+req_id,
        "content":data})
    return {"requested":True,"command_id":req_id,"requested_at":payload["requested_at"]}

def check(now=None,fix=True,trace_fetch=known_run,control_fetch=None,dispatch=request):
    now=now or datetime.now(timezone.utc)
    previous=load(REPORT,{"projects":{}})
    outcomes={}
    for project in CONFIG:
        old=(previous.get("projects") or {}).get(project,{})
        try:
            run=trace_fetch(project)
            if control_fetch:
                cmd=control_fetch(project)
            else:
                # Read control with per-branch ref, not main!
                raw=api("contents/"+CONFIG[project]["control"],branch=CONFIG[project]["branch"])
                cmd=json.loads(base64.b64decode(raw["content"]).decode("utf8"))
            check_result=evaluate(project,now,old,command=cmd,run=run)
            key=check_result.get("backlog_signature")
            if key and key!=old.get("backlog_signature"):
                old["attempts"]=0
            if fix and check_result.get("should_dispatch"):
                answer=dispatch(project,now,check_result)
                check_result["dispatch"]=answer
                if answer.get("requested"):
                    check_result["status"]="dispatch_requested_awaiting_run"
                    old["attempts"]=int(old.get("attempts") or 0)+1
                    old["last_request_at"]=now.isoformat()
                    old["command_id"]=answer.get("command_id")
                else:
                    check_result["status"]="remote_command_active"
            check_result["attempts"]=old.get("attempts") or 0
            check_result["last_request_at"]=old.get("last_request_at")
            if old.get("command_id"):
                check_result["last_requested_command_id"]=old["command_id"]
            if key:check_result["backlog_signature"]=key
            elif not check_result.get("pending_count"):
                check_result["attempts"]=0
            outcomes[project]=check_result
        except Exception as exc:
            outcomes[project]={"project":project,"checked_at":now.isoformat(),
                  "status":"guard_error","error":str(exc)[:300],
                  "pending_count":len(pending(project)),
                  "should_dispatch":False}
    save(REPORT,{"version":1,"checked_at":now.isoformat(),"projects":outcomes,
       "policy":{"due_minutes":5,"ack_grace_minutes":15,"max_requests_per_backlog":3,
                 "no_auto_editorial_content":True,"execution_requires_confirmation":True}})
    print("TT_EDITORIAL_RUN_GUARD "+json.dumps({k:{
        "status":v["status"],"pending":v.get("pending_count",0),
        "dispatch":v.get("dispatch",{}).get("requested",False)}
        for k,v in outcomes.items()},ensure_ascii=False),flush=True)
    return outcomes

def selftest():
    global ROOT
    old=ROOT
    with tempfile.TemporaryDirectory() as td:
        ROOT=Path(td)
        try:
            now=datetime(2026,10,12,19,30,tzinfo=timezone.utc)
            save("telegram/lifecycle-baseline.json",{"activated_at":"2026-10-12T15:25:23Z",
                "project_state":{"ttittulares":{"historic_max_message_id":3566},
                    "ttendencias":{"historic_max_message_id":719}}})
            save("ttittulares/editorial-queue.json",{"items":[
                {"event_id":"a","status":"PROCESSING","selected_at":"2026-10-12T19:20:00Z"}]})
            save("telegram/ttittulares-deliveries.json",{"items":[
                {"event_id":"a","telegram_message_id":3582,"status":"sent","final":False,
                 "started_at":"2026-10-12T19:20:00Z"}]})
            save("trends/editorial-queue.json",{"items":[]})
            save("trends/telegram-image-deliveries.json",{"items":[]})
            commands={"ttittulares":{"requested_at":"2026-10-12T18:00:00Z"},
                      "ttendencias":{"requested_at":"2026-10-12T18:00:00Z"}}
            calls=[]
            def fake_dispatch(p,dt,j):
                calls.append(p);return {"requested":True,"command_id":"new","requested_at":dt.isoformat()}
            res=check(now,fix=True,trace_fetch=lambda p:{},
                      control_fetch=lambda p:commands[p],dispatch=fake_dispatch)
            assert calls==["ttittulares"] and res["ttittulares"]["status"]=="dispatch_requested_awaiting_run",res
            res2=check(now+timedelta(minutes=4),fix=True,trace_fetch=lambda p:{},
                       control_fetch=lambda p:commands[p],dispatch=fake_dispatch)
            assert len(calls)==1 and res2["ttittulares"]["status"]=="retry_cooldown",res2
            active=evaluate("ttittulares",now,{},run={"status":"RUNNING",
                    "updated_at":now.isoformat()},command=commands["ttittulares"])
            assert active["status"]=="editor_running_acknowledged",active
            done=evaluate("ttittulares",now,{},run={"status":"DONE",
                    "finished_at":(now-timedelta(minutes=2)).isoformat()},command=commands["ttittulares"])
            assert done["status"]=="editorial_run_finished_delivery_unverified",done
            # Terminal Telegram decisions suppress re-trigger even with a stale APP queue.
            save("telegram/ttittulares-deliveries.json",{"items":[
                {"event_id":"a","telegram_message_id":3582,"status":"deleted","final":False}]})
            assert pending("ttittulares")==[]
            print("TT_EDITORIAL_RUN_GUARD_SELFTEST_OK")
        finally:ROOT=old

if __name__=="__main__":
    if "selftest" in sys.argv:selftest()
    else:check()
