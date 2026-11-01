#!/usr/bin/env python3
"""Validate iOS GAG fallback; request an independent TTImages delivery.

The user's ChatGPT-generated image cannot be transferred by a prompt alone.
Only enqueue a PC-generated fallback when the exact episode lacks a catalogued Site image.
"""
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
EXPLAINED=ROOT/"trends/telegram-manual-explained.json"
CATALOG=ROOT/"trends/site-ai-images.json"
RECEIPTS=ROOT/"pilot/ttactualidad-gag-receipts.json"

def process(payload, explained, catalog, receipts):
    request_id=str(payload.get("request_id") or "")
    target_id=str(payload.get("target_id") or "")
    name=str(payload.get("name") or "")
    rev=payload.get("revision")
    explanation=str(payload.get("explanation") or "")
    explained_at=str(payload.get("explained_at") or "")
    if not re.fullmatch(r"[a-f0-9-]{16,64}",request_id):
        raise ValueError("invalid_request_id")
    if not re.fullmatch(r"[A-Za-z0-9_-]{3,160}",target_id):
        raise ValueError("invalid_target_id")
    if not isinstance(rev,int) or isinstance(rev,bool) or rev<0:
        raise ValueError("invalid_revision")
    if not explanation.strip() or not explained_at or not name:
        raise ValueError("missing_editorial_identity")
    previous=next((x for x in receipts.get("items",[]) if x.get("request_id")==request_id),None)
    if previous:
        return previous,False
    current=next((x for x in explained.get("items",[])
                 if x.get("id")==target_id and int(x.get("revision") or 0)==rev
                 and x.get("explanation")==explanation and x.get("explained_at")==explained_at
                 and str(x.get("name") or "")==name and
                 str(x.get("status") or "").lower()=="explained"),None)
    status="queued" if current else "stale_editorial"
    if current:
        already=any(x.get("target_id")==target_id and
                    x.get("revision")==rev and
                    x.get("explanation")==explanation and
                    x.get("explained_at")==explained_at and
                    str(x.get("image_url") or "").startswith("https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/") and
                    re.fullmatch(r"[a-f0-9]{64}",str(x.get("sha256") or ""))
                    for x in catalog.get("images",[]))
        if already:
            status="already_catalogued"
        else:
            current["ai_image_regenerate_request_version"]=int(current.get("ai_image_regenerate_request_version") or 0)+1
            current["gag_auto_request_id"]=request_id
    receipt={"request_id":request_id,"target_id":target_id,"revision":rev,
             "status":status,"source":"ios_gag_fallback_v1",
             "at":datetime.now(timezone.utc).isoformat().replace("+00:00","Z")}
    receipts.setdefault("items",[]).append(receipt)
    receipts["items"]=receipts["items"][-120:]
    return receipt,status=="queued"

def main():
    payload=json.loads(os.environ["TT_ACTUALIDAD_GAG_JSON"])
    explained=json.loads(EXPLAINED.read_text(encoding="utf8"))
    catalog=json.loads(CATALOG.read_text(encoding="utf8"))
    receipts=json.loads(RECEIPTS.read_text(encoding="utf8")) if RECEIPTS.exists() else {"version":1,"items":[]}
    receipt,queued=process(payload,explained,catalog,receipts)
    if queued: EXPLAINED.write_text(json.dumps(explained,ensure_ascii=False,indent=2)+"\n",encoding="utf8")
    RECEIPTS.parent.mkdir(parents=True,exist_ok=True)
    RECEIPTS.write_text(json.dumps(receipts,ensure_ascii=False,indent=2)+"\n",encoding="utf8")
    print("TT_ACTUALIDAD_GAG_FALLBACK",receipt["status"],receipt["target_id"],receipt["request_id"])

if __name__=="__main__":
    main()
