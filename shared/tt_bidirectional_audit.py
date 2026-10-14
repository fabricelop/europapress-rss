#!/usr/bin/env python3
"""Reconcile APP state <-> Telegram delivery ledger, without modifying either.

Telegram Bot API cannot list bot messages in a private chat. A confirmed API
send/edit and a persisted delivery ID are the strongest available evidence.
Never infer a deletion without an explicit callback/decision.
"""
import json
import re
import sys
import unicodedata
from pathlib import Path
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[1]
OPEN={"processing","preparing","update","ready","in_progress","explained"}
CLOSED={"deleted","dismissed","removed","published","delete_pending","delete_failed"}

def read(path,default=None):
    try:
        return json.loads((ROOT/path).read_text(encoding="utf-8"))
    except (OSError,ValueError):
        return default if default is not None else {}

def when(s):
    try:
        d=datetime.fromisoformat(str(s or "").replace("Z","+00:00"))
        return (d.replace(tzinfo=timezone.utc) if d.tzinfo is None
                else d.astimezone(timezone.utc))
    except (TypeError,ValueError):
        return None

def normalize(value):
    value=unicodedata.normalize("NFKD",str(value or ""))
    return re.sub(r"\s+"," ",''.join(x for x in value if not unicodedata.combining(x)).strip().lower())

def audit(project,now=None):
    now=now or datetime.now(timezone.utc)
    base=read("telegram/lifecycle-baseline.json")
    point=(base.get("project_state") or {}).get(project,{})
    cutoff=when(base.get("activated_at"))
    watermark=int(point.get("historic_max_message_id") or 0)
    protected=set(map(str,point.get("preserve_pending_ids") or []))
    is_tti=project=="ttittulares"
    ledger_name=("telegram/ttittulares-deliveries.json" if is_tti
                 else "trends/telegram-image-deliveries.json")
    queue_name=("ttittulares/editorial-queue.json" if is_tti
                else "trends/editorial-queue.json")
    rows=read(ledger_name,{"items":[]}).get("items") or []
    app_queue=read(queue_name,{"items":[]}).get("items") or []
    catalog=read("ttittulares/status.json" if is_tti else "trends/requests.json")
    archived=read("ttittulares/prepared.json" if is_tti else "trends/telegram-manual-explained.json")
    decisions=read("ttittulares/decisions.json" if is_tti else "trends/mobile-decisions.json")
    recent=read("trends/recent.json") if not is_tti else {}
    if any(not isinstance(x,list) for x in (rows,app_queue,archived.get("items") or [],
                                              decisions.get("items") or [])):
        raise RuntimeError("Invalid list in app or Telegram ledger")
    active={}
    history={}
    for row in rows:
        eid=str(row.get("event_id") or "")
        if not eid:continue
        mid=int(row.get("telegram_message_id") or 0)
        if mid<=watermark:continue
        prev=history.get(eid)
        if prev is None or mid>=int(prev.get("telegram_message_id") or 0):
            history[eid]=row
        if str(row.get("status") or "").lower()=="sent" and mid>0:
            if eid not in active or mid>=int(active[eid].get("telegram_message_id") or 0):
                active[eid]=row
    # Telegram delete tombstones override any earlier sent acknowledgement.
    terminal_rows=[x for x in rows
        if int(x.get("telegram_message_id") or 0)>watermark
        and str(x.get("status") or "").lower() in CLOSED]
    terminal_ids={str(x.get("event_id") or "") for x in terminal_rows}
    active={eid:row for eid,row in active.items() if eid not in terminal_ids}
    decisions_by_id={str(x.get("event_id") or x.get("id") or ""):
                     str(x.get("status") or "").lower()
                     for x in decisions.get("items",[])}
    # A terminal decision on a grouped leader applies to the explicit members
    # of that SAME persisted group. This prevents a deleted/published group
    # card from resurfacing as "app_without_telegram" for a follower.
    terminal_groups={}
    for row in terminal_rows:
        leader_id=str(row.get("event_id") or "")
        if not leader_id:continue
        terminal_groups[leader_id]={
            "group_id":str(row.get("group_id") or ""),
            "members":{str(x) for x in (row.get("group_member_ids") or []) if str(x)}
        }
    # The user's Telegram delete callback is authoritative. Keep Explicadas
    # and READY as *history*, not a fresh active APP row after delete.
    for eid in terminal_ids:
        decisions_by_id[eid]="deleted"
    app={}
    def add(row,source,stamp):
        eid=str(row.get("event_id") or row.get("id") or "")
        if not eid:return
        if decisions_by_id.get(eid) in CLOSED:return
        if not is_tti:
            leader_id=str(row.get("group_leader_id") or "")
            row_group=str(row.get("group_id") or row.get("explanation_group_id") or "")
            terminal_leader=terminal_groups.get(leader_id) if leader_id and leader_id!=eid else None
            if terminal_leader:
                members=terminal_leader["members"]
                leader_group=terminal_leader["group_id"]
                if eid in members or (row_group and leader_group and row_group==leader_group):
                    return
        start=when(stamp)
        if cutoff and eid not in protected and (start is None or start<=cutoff):
            return
        status=str(row.get("status") or "processing").lower()
        if status not in OPEN:return
        if eid in app:
            app[eid]["sources"].add(source)
            app[eid]["has_final_copy"]=app[eid]["has_final_copy"] or bool(row.get("explanation") or row.get("editorial_verified"))
            if not app[eid].get("group_leader_id") and row.get("group_leader_id"):
                app[eid]["group_leader_id"]=str(row.get("group_leader_id") or "")
            if not app[eid].get("group_id") and (row.get("group_id") or row.get("explanation_group_id")):
                app[eid]["group_id"]=str(row.get("group_id") or row.get("explanation_group_id") or "")
            return
        app[eid]={"id":eid,"title":str(row.get("name") or row.get("title") or eid),
                  "status":status,"sources":{source},
                  "created":start.isoformat() if start else None,
                  "revision":int(row.get("revision") or 0),
                  "group_leader_id":str(row.get("group_leader_id") or ""),
                  "group_id":str(row.get("group_id") or row.get("explanation_group_id") or ""),
                  "has_final_copy":bool(row.get("explanation") or row.get("editorial_verified") or source=="app_listas")}
    for x in app_queue:
        add(x,"editorial_queue",x.get("requested_at") or x.get("selected_at"))
    if is_tti:
        for x in catalog.get("processing_items",[]):
            add(x,"app_processing",x.get("selected_at"))
        for x in archived.get("items",[]):
            add({**x,"status":"ready"},"app_listas",
                x.get("prepared_at") or x.get("selected_at"))
    else:
        for x in catalog.get("requests",[]):
            if str(x.get("status") or "").lower() in OPEN:
                add(x,"app_requests",x.get("requested_at"))
        for x in archived.get("items",[]):
            if (str(x.get("status") or "").lower() in OPEN or
                    str(x.get("explanation") or "").strip()):
                add({**x,"status":"explained"},"app_explicadas",
                    x.get("requested_at") or x.get("explained_at"))
    issues=[]
    matched=0
    open_index={normalize(x["title"]):eid for eid,x in app.items()}
    # App -> Telegram: every currently open app entry needs its own
    # send-acknowledged card, unless an explicit persisted group leader exists.
    for eid,x in app.items():
        delivery=active.get(eid)
        if not delivery:
            # A grouped member may intentionally share the leader's single Telegram
            # package. Only accept that exception when the member explicitly persists
            # a different group_leader_id and that leader has a live delivery.
            leader_id=str(x.get("group_leader_id") or "")
            if not is_tti and leader_id and leader_id!=eid:
                leader_delivery=active.get(leader_id)
                if leader_delivery:
                    member_group=str(x.get("group_id") or "")
                    leader_group=str(leader_delivery.get("group_id") or "")
                    if not member_group or not leader_group or member_group==leader_group:
                        matched+=1
                        continue
            old=history.get(eid)
            kind="app_open_after_telegram_delete" if old and str(old.get("status") or "").lower() in CLOSED else "app_without_telegram"
            issues.append({"kind":kind,"id":eid,"title":x["title"],
                           "source":sorted(x["sources"]),"repairable":kind=="app_without_telegram"})
            continue
        matched+=1
        if x["status"] in {"explained","ready"} and x["has_final_copy"] and delivery.get("final") is not True:
            # Ready queue rows may lack full text. Sender still must finish.
            issues.append({"kind":"app_final_not_delivered","id":eid,
                           "title":x["title"],"message_id":delivery["telegram_message_id"],
                           "repairable":True})
    # Telegram -> App: active news/trends must exist in current app state or
    # its durable editorial history; do NOT equate an old closed row with active.
    ready_ids={str(x.get("event_id") or x.get("id") or "") for x in archived.get("items",[])}
    req_ids={str(x.get("id") or "") for x in catalog.get("requests",[])} if not is_tti else set()
    for eid,row in active.items():
        if eid in app or eid in ready_ids or eid in req_ids:
            continue
        # A saved final may be represented by an explanation in the full
        # trend history; use exact ID before falling back to strict name.
        titled=normalize(row.get("name") or row.get("title"))
        if titled in open_index and open_index[titled]!=eid:
            issues.append({"kind":"telegram_mismatched_id","id":eid,
                           "app_id":open_index[titled],"title":str(row.get("name") or row.get("title") or eid),
                           "message_id":int(row.get("telegram_message_id") or 0),
                           "repairable":False})
        else:
            issues.append({"kind":"telegram_without_app","id":eid,
                           "title":str(row.get("name") or row.get("title") or eid),
                           "message_id":int(row.get("telegram_message_id") or 0),
                           "repairable":False})
    # Supplement: visible Top 10 rows not in the ongoing requests/queue,
    # but do not automatically create messages for old/closed topics.
    # They require editorial verification, not a fake automatic closure.
    top_without_queue=[]
    if not is_tti:
        recently=recent.get("items") or []
        catalog_names={normalize(v.get("name")) for v in
                       catalog.get("requests",[]) if v.get("name")}
        active_names={normalize(v.get("name") or v.get("title")) for v in active.values()}
        closed_names={normalize(v.get("name") or v.get("title")) for v in
                      rows if str(v.get("status") or "").lower() in CLOSED}
        for x in recently[:10]:
            n=normalize(x.get("name"))
            entered=when(x.get("entered_top10_at"))
            if (n and n not in catalog_names and n not in active_names and
                n not in closed_names and entered and cutoff and entered>cutoff and
                (now-entered).total_seconds()>300):
                top_without_queue.append({"rank":x.get("rank"),"name":x.get("name")})
    return {"project":project,"checked_at":now.isoformat(),
            "verification":"persisted API acknowledgements, editorial state and Telegram callback ledger; chat history cannot be enumerated",
            "app_open_count":len(app),"telegram_live_count":len(active),
            "matched_count":matched,"issues_count":len(issues),
            "issues":issues[:100],"untracked_top10":top_without_queue,
            "app_ids":sorted(app),"telegram_ids":sorted(active)}

def selftest():
    import tempfile
    global ROOT
    original=ROOT
    with tempfile.TemporaryDirectory() as d:
        ROOT=Path(d)
        try:
            def put(p,j):
                f=ROOT/p;f.parent.mkdir(parents=True,exist_ok=True)
                f.write_text(json.dumps(j))
            put("telegram/lifecycle-baseline.json",{"activated_at":"2026-10-12T15:25:23Z",
                "project_state":{"ttittulares":{"historic_max_message_id":3566},
                                 "ttendencias":{"historic_max_message_id":719}}})
            put("ttittulares/editorial-queue.json",{"items":[
                {"event_id":"active","title":"Noticia","selected_at":"2026-10-12T18:10:00Z","status":"PROCESSING"},
                {"event_id":"missing","title":"No enviada","selected_at":"2026-10-12T18:10:00Z","status":"PROCESSING"}]})
            put("telegram/ttittulares-deliveries.json",{"items":[
                {"event_id":"active","telegram_message_id":3567,"status":"sent","final":False},
                {"event_id":"orphan","title":"Resto","telegram_message_id":3568,"status":"sent","final":False}]})
            j=audit("ttittulares",datetime(2026,10,12,19,tzinfo=timezone.utc))
            assert j["matched_count"]==1 and j["issues_count"]==2,j
            assert {r["kind"] for r in j["issues"]}=={"app_without_telegram","telegram_without_app"},j
            put("trends/editorial-queue.json",{"items":[
                {"id":"tt","name":"Tendencia","status":"preparing",
                 "requested_at":"2026-10-12T18:10:00Z"}]})
            put("trends/telegram-image-deliveries.json",{"items":[
                {"event_id":"tt","telegram_message_id":720,"status":"sent","final":False}]})
            x=audit("ttendencias",datetime(2026,10,12,19,tzinfo=timezone.utc))
            assert x["matched_count"]==1 and x["issues_count"]==0,x
            put("trends/requests.json",{"requests":[
                {"id":"member","name":"Miembro","status":"explained",
                 "requested_at":"2026-10-12T18:11:00Z","explanation":"Compartida",
                 "group_id":"grp","group_leader_id":"tt"}]})
            put("trends/telegram-image-deliveries.json",{"items":[
                {"event_id":"tt","telegram_message_id":720,"status":"sent","final":True,
                 "group_id":"grp"}]})
            grouped=audit("ttendencias",datetime(2026,10,12,19,tzinfo=timezone.utc))
            assert grouped["matched_count"]==2 and grouped["issues_count"]==0,grouped
            # Deleting the one Telegram package for an explicit group closes
            # the leader AND its follower from the live-app audit surface.
            put("trends/telegram-image-deliveries.json",{"items":[
                {"event_id":"tt","telegram_message_id":720,"status":"deleted","final":True,
                 "group_id":"grp","group_member_ids":["tt","member"]}]})
            grouped_deleted=audit("ttendencias",datetime(2026,10,12,19,tzinfo=timezone.utc))
            assert grouped_deleted["app_open_count"]==0 and grouped_deleted["issues_count"]==0,grouped_deleted
            put("trends/requests.json",{"requests":[]})
            put("trends/telegram-manual-explained.json",{"items":[
                {"id":"closed","name":"Explicación archivada","status":"explained",
                 "explained_at":"2026-10-12T18:12:00Z","explanation":"Verificada"}]})
            put("trends/telegram-image-deliveries.json",{"items":[
                {"event_id":"tt","telegram_message_id":720,"status":"sent","final":False},
                {"event_id":"closed","telegram_message_id":721,"status":"deleted","final":True}]})
            closed=audit("ttendencias",datetime(2026,10,12,19,tzinfo=timezone.utc))
            assert closed["issues_count"]==0 and closed["app_open_count"]==1,closed
            print("TT_BIDIRECTIONAL_AUDIT_SELFTEST_OK")
        finally:ROOT=original

if __name__=="__main__":
    if "selftest" in sys.argv:selftest()
    else:
        for project in ("ttittulares","ttendencias"):
            report=audit(project)
            out=ROOT/"telegram"/("bidirectional-audit-"+project+".json")
            out.parent.mkdir(parents=True,exist_ok=True)
            out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
            print("TT_BIDIRECTIONAL_AUDIT",project,
                  "app="+str(report["app_open_count"]),
                  "telegram="+str(report["telegram_live_count"]),
                  "matched="+str(report["matched_count"]),
                  "mismatches="+str(report["issues_count"]),
                  "top10_untracked="+str(len(report["untracked_top10"])),flush=True)
