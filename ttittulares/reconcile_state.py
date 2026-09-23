#!/usr/bin/env python3
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
QUEUE=ROOT/"telegram"/"editorial-processing.json"
PREP=ROOT/"ttittulares"/"prepared.json"

def load(p,default):
    try:return json.loads(p.read_text(encoding="utf-8"))
    except Exception:return default

def save(p,obj):
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

q=load(QUEUE,{"items":[]})
p=load(PREP,{"items":[]})
ready={str(x.get("event_id")):x for x in p.get("items",[]) if x.get("event_id")}
changed=0
for item in q.get("items",[]):
    eid=str(item.get("event_id") or "")
    pr=ready.get(eid)
    if pr and str(item.get("status") or "")=="PROCESSING":
        item["status"]="READY"
        item["delivered_at"]=pr.get("prepared_at") or datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
        item["delivery_confirmation"]="prepared_web"
        changed+=1
if changed:
    q["updated_at"]=datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
    save(QUEUE,q)
print("RECONCILED_READY",changed)
