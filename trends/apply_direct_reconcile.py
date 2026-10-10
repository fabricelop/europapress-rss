#!/usr/bin/env python3
from __future__ import annotations
import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT=Path(__file__).resolve().parent.parent
TRENDS=ROOT/"trends"
MADRID=ZoneInfo("Europe/Madrid")
CMD=TRENDS/"direct-reconcile-command.json"

def load(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def save(path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")

def main():
    if not CMD.exists():
        print("TTENDENCIAS_DIRECT_RECONCILE_NO_COMMAND")
        return 0
    cmd=load(CMD,{})
    if cmd.get("project")!="TTendencias" or cmd.get("action")!="link_existing_group":
        raise SystemExit("Comando directo no válido")

    explained_path=TRENDS/"telegram-manual-explained.json"
    requests_path=TRENDS/"requests.json"
    queue_path=TRENDS/"editorial-queue.json"
    explained=load(explained_path,{"items":[]})
    requests=load(requests_path,{"requests":[]})
    queue=load(queue_path,{"items":[]})

    leader_id=str(cmd.get("group_leader_id") or "")
    leader_rev=int(cmd.get("group_leader_revision") or 0)
    group_id=str(cmd.get("group_id") or "")
    leader=next((x for x in explained.get("items",[]) if str(x.get("id") or "")==leader_id and int(x.get("revision") or 0)==leader_rev and str(x.get("group_id") or x.get("explanation_group_id") or "")==group_id),None)
    if not leader or str(leader.get("status") or "").lower()!="explained":
        raise SystemExit("Líder explained no encontrado")

    now=datetime.now(MADRID).isoformat(timespec="seconds")
    members=cmd.get("members") or []
    pairs={(str(m.get("id") or ""),int(m.get("revision") or 0)) for m in members}
    if not pairs:
        raise SystemExit("Sin miembros")

    for m in members:
        mid=str(m.get("id") or "")
        rev=int(m.get("revision") or 0)
        req=next((x for x in requests.get("requests",[]) if str(x.get("id") or "")==mid and int(x.get("revision") or 0)==rev),None)
        if req is None:
            raise SystemExit(f"Request inexistente {mid}:r{rev}")
        if str(req.get("status") or "") not in {"preparing","update","explained"}:
            raise SystemExit(f"Estado no reconciliable {mid}:r{rev}={req.get('status')}")
        req.update({
            "status":"explained",
            "explained_at":leader.get("explained_at") or now,
            "last_attempt_at":now,
            "explanation":leader.get("explanation") or "",
            "closer_text":leader.get("closer_text") or "",
            "category":leader.get("category") or "Deportes",
            "rank_at_explanation":m.get("rank"),
            "source":"editorial_chat_direct_group_link",
            "editorial_engine":"chat-direct",
            "group_id":group_id,
            "explanation_group_id":group_id,
            "group_title":leader.get("group_title") or "",
            "group_leader_id":leader_id,
            "trend_names":leader.get("trend_names") or [],
            "trend_context":leader.get("trend_context") or [],
            "grouped_member_revisions":leader.get("grouped_member_revisions") or [],
            "verification_sources":leader.get("verification_sources") or [],
            "news_disposition":"ignored",
            "news_note":leader.get("news_note") or "",
            "disable_ai_image":False,
            "image_strategy":"ai_plus_fallback",
            "image_pending":False,
            "rewrite_pending":False,
            "material_novelty_verified":False,
            "grouped_into_existing_card":True,
        })

    requests["updated_at"]=now
    queue["items"]=[x for x in (queue.get("items") or []) if (str(x.get("id") or ""),int(x.get("revision") or 0)) not in pairs]
    queue["count"]=len(queue["items"])
    queue["updated_at"]=now
    save(requests_path,requests)
    save(queue_path,queue)
    CMD.unlink()
    print("TTENDENCIAS_DIRECT_RECONCILE_DONE",len(members),queue["count"])
    return 0

if __name__=="__main__":
    raise SystemExit(main())
