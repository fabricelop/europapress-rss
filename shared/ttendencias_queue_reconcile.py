#!/usr/bin/env python3
"""Persist verified TTendencias editorial results independently of Telegram.

Queue may be ahead of the large requests.json file. Reconcile exact
(id, revision) after editorial verification, never after transport confirmation.
Terminal decisions and newer revisions remain protected.
"""
import json
import tempfile
import sys
from pathlib import Path
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[1]

def read(path,default=None):
    source=ROOT/path
    if not source.exists():return default
    return json.loads(source.read_text(encoding="utf-8"))

def write(path,obj):
    filename=ROOT/path
    filename.parent.mkdir(parents=True,exist_ok=True)
    filename.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def reconcile():
    q=read("trends/editorial-queue.json",{"items":[]})
    d=read("trends/telegram-image-deliveries.json",{"items":[]})
    reqs=read("trends/requests.json",{"requests":[]})
    manual=read("trends/telegram-manual-explained.json",{"items":[]})
    if not all(isinstance(x,dict) for x in (q,d,reqs,manual)):
        raise RuntimeError("Invalid JSON root")
    if not all(isinstance(a,list) for a in (q.get("items"),d.get("items"),reqs.get("requests"),manual.get("items"))):
        raise RuntimeError("Invalid editorial list schema")
    byreq={str(row.get("id") or ""):row for row in reqs["requests"]}
    bymanual={(str(row.get("id") or ""),int(row.get("revision") or 0)):row
              for row in manual["items"]}
    terminal={"deleted","dismissed","published","removed","delete_pending","delete_failed"}
    blocked={str(row.get("event_id") or "") for row in d["items"]
             if str(row.get("status") or "").lower() in terminal}
    promoted=[]
    remain=[]
    for queue_row in q["items"]:
        tid=str(queue_row.get("id") or "")
        rev=int(queue_row.get("revision") or 0)
        source=(str(queue_row.get("explanation") or "").strip(),
                str(queue_row.get("closer_text") or "").strip())
        existing=byreq.get(tid)
        if (queue_row.get("anticipation_request")
                or str(queue_row.get("status") or "").lower()!="explained"
                or queue_row.get("editorial_verified") is not True
                or not source[0] or tid in blocked
                or existing and int(existing.get("revision") or 0)>rev
                or existing and str(existing.get("status") or "").lower() in terminal):
            remain.append(queue_row)
            continue
        stamp=str(queue_row.get("explained_at") or datetime.now(timezone.utc).isoformat())
        if (len(source[0]+"\n"+source[1])>256):
            raise RuntimeError("Editorial text too long: "+tid)
        fields={
            "id":tid,"name":queue_row.get("name"),"rank":queue_row.get("rank"),
            "revision":rev,"status":"explained","explanation":source[0],
            "closer_text":source[1],"explained_at":stamp,
            "editorial_verified":True,
            "source_url":queue_row.get("source_url"),
            "verification_sources":queue_row.get("verification_sources") or []
        }
        # Preserve the current explanation_only metadata from the compact queue.
        # This is important when requests.json/manual-explained are too large for
        # the editor connector and the queue is the verified hand-off.
        for key in (
            "category","group_id","explanation_group_id","group_leader_id",
            "group_title","trend_names","trend_context","grouped_member_revisions",
            "with_image","disable_ai_image","image_strategy","news_note"
        ):
            if key in queue_row:
                fields[key]=queue_row.get(key)
        leader_id=str(queue_row.get("group_leader_id") or tid)
        group_id=str(queue_row.get("explanation_group_id") or queue_row.get("group_id") or "")
        grouped_follower=bool(group_id and leader_id and leader_id!=tid)
        fields["grouped_into_existing_card"]=grouped_follower
        if existing is None:
            request={**queue_row,**fields}
            reqs["requests"].append(request)
            byreq[tid]=request
        else:
            existing.update({k:v for k,v in fields.items() if v is not None})
        # A grouped event has one canonical explanation row (the leader), while
        # every member request and every Telegram message is still closed.
        if not grouped_follower:
            k=(tid,rev)
            if k in bymanual:
                bymanual[k].update({key:value for key,value in fields.items() if value is not None})
            else:
                final={**fields}
                manual["items"].append(final)
                bymanual[k]=final
        promoted.append(tid)
    if promoted:
        q["items"]=remain
        q["count"]=len(remain)
        now=datetime.now(timezone.utc).isoformat()
        q["updated_at"]=now
        reqs["updated_at"]=now
        manual["updated_at"]=now
        write("trends/requests.json",reqs)
        write("trends/telegram-manual-explained.json",manual)
        write("trends/editorial-queue.json",q)
    print("TTENDENCIAS_EDITORIAL_RECONCILE verified="+str(len(promoted))+
          " ids="+",".join(promoted)+" queue_remaining="+str(len(remain)),flush=True)
    return promoted

def selftest():
    global ROOT
    original=ROOT
    with tempfile.TemporaryDirectory() as td:
        ROOT=Path(td)
        try:
            write("trends/editorial-queue.json",{"items":[
                {"id":"a","name":"Evento","rank":3,"revision":0,
                 "status":"explained","editorial_verified":True,
                 "explanation":"TT#3 Evento confirmado","closer_text":"🌶️ Remate"},
                {"id":"b","name":"Validado sin Telegram","revision":0,
                 "status":"explained","editorial_verified":True,
                 "explanation":"Verificado"},
                {"id":"c","name":"Sin validar","revision":0,
                 "status":"explained","editorial_verified":False,
                 "explanation":"No apto"}]})
            write("trends/telegram-image-deliveries.json",{"items":[
                {"event_id":"a","revision":0,"telegram_message_id":44,
                 "status":"sent","final":True}]})
            write("trends/requests.json",{"requests":[]})
            write("trends/telegram-manual-explained.json",{"items":[]})
            assert reconcile()==["a","b"]
            assert reconcile()==[]
            assert read("trends/requests.json")["requests"][0]["status"]=="explained"
            assert len(read("trends/telegram-manual-explained.json")["items"])==2
            assert read("trends/editorial-queue.json")["items"][0]["id"]=="c"
            assert all("telegram_message_id" not in row for row in read("trends/telegram-manual-explained.json")["items"])
            print("TTENDENCIAS_EDITORIAL_RECONCILE_SELFTEST_OK")
        finally:ROOT=original

if __name__=="__main__":
    if len(sys.argv)>1 and sys.argv[1]=="selftest":selftest()
    else:reconcile()
