#!/usr/bin/env python3
"""Importa propuestas Telegram confirmadas a la investigación editorial.
No requiere fuentes iniciales: investigar no equivale a publicar sin verificar.
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PROPOSALS=ROOT/"telegram"/"ttittulares-user-proposals.json"
PROCESSING=ROOT/"telegram"/"editorial-processing.json"

def import_rows(proposals,processing,at):
    ideas=proposals.setdefault("items",[])
    items=processing.setdefault("items",[])
    existing={str(x.get("event_id")) for x in items}
    count=0
    for idea in ideas:
        if idea.get("status")!="PENDING_RESEARCH":
            continue
        eid=str(idea.get("event_id") or "")
        body=str(idea.get("content") or "").strip()
        if not eid.startswith("telegram-") or len(body)<5:
            idea["status"]="INVALID"
            idea["checked_at"]=at
            continue
        if eid not in existing:
            title=(body.splitlines()[0] or body).strip()[:240]
            items.append({
                "event_id":eid,
                "title":title,
                "telegram_user_request":body[:3000],
                "sources":[],
                "source_count":0,
                "verified_source_count":0,
                "status":"PROCESSING",
                "selection_mode":"TELEGRAM_USER_SUGGESTION",
                "manual_submission":True,
                "manual_investigation_requested":True,
                "allow_zero_initial_sources":True,
                "selected_at":idea.get("submitted_at") or at,
                "revision":1
            })
            existing.add(eid)
            count+=1
        idea["status"]="QUEUED_FOR_INVESTIGATION"
        idea["queued_at"]=at
    if count:
        processing["updated_at"]=at
    proposals["updated_at"]=at
    return count

def run_selftest():
    stamp="2026-10-09T17:00:00Z"
    input_ideas={"items":[{"event_id":"telegram-123","content":"Atasco en la A-6","status":"PENDING_RESEARCH"}]}
    q={"items":[]}
    assert import_rows(input_ideas,q,stamp)==1
    assert q["items"][0]["allow_zero_initial_sources"] is True
    assert q["items"][0]["sources"]==[]
    assert import_rows(input_ideas,q,stamp)==0
    assert len(q["items"])==1
    assert input_ideas["items"][0]["status"]=="QUEUED_FOR_INVESTIGATION"
    print("TTI_TELEGRAM_PROPOSALS_SELFTEST_OK")

def main():
    if "--selftest" in sys.argv:
        return run_selftest()
    ideas=json.loads(PROPOSALS.read_text(encoding="utf8"))
    q=json.loads(PROCESSING.read_text(encoding="utf8"))
    if not isinstance(ideas.get("items"),list) or not isinstance(q.get("items"),list):
        raise SystemExit("Invalid proposals or editorial-processing schema")
    now=datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
    had_pending=any(row.get("status")=="PENDING_RESEARCH" for row in ideas["items"])
    count=import_rows(ideas,q,now)
    if had_pending:
        PROPOSALS.write_text(json.dumps(ideas,ensure_ascii=False,indent=2)+"\n",encoding="utf8")
        if count:
            PROCESSING.write_text(json.dumps(q,ensure_ascii=False,indent=2)+"\n",encoding="utf8")
    print("TTI_TELEGRAM_PROPOSALS_IMPORTED",count)

if __name__=="__main__":
    main()
