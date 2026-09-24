#!/usr/bin/env python3
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
Q=ROOT/"telegram"/"editorial-processing.json"
OUT=ROOT/"ttittulares"/"editorial-queue.json"

def load(p,d):
    try:return json.loads(p.read_text(encoding="utf-8"))
    except Exception:return d

def save(p,o):
    p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

q=load(Q,{"items":[]})
items=[]
for x in q.get("items",[]) or []:
    if str(x.get("status") or "")!="PROCESSING":
        continue
    items.append({
        "event_id":x.get("event_id"),
        "title":x.get("title") or "",
        "url":x.get("url") or "",
        "sources":x.get("sources") or [],
        "source_count":int(x.get("source_count") or 0),
        "selected_at":x.get("selected_at"),
        "selection_mode":x.get("selection_mode") or "",
        "revision":int(x.get("revision") or 1),
        "rewrite_request":x.get("rewrite_request") or x.get("rewrite_instruction") or "",
        "parent_event_id":x.get("parent_event_id"),
        "update_context":x.get("update_context"),
        "with_image":True,
        "image_mode":"existing_web_image",
        "image_instruction":"Busca una imagen existente y relevante al hecho en una fuente oficial/primaria o medio fiable. Haz al menos una búsqueda específica y, si falla, una segunda vía u og:image de una fuente usada. No generes imágenes. Guarda URL directa, fuente, página de origen y rights_status. Si no encuentras una adecuada, deja constancia explícita.",
    })
items.sort(key=lambda x:str(x.get("selected_at") or ""))
save(OUT,{
    "project":"TTiTTulares",
    "updated_at":datetime.now(timezone.utc).isoformat().replace("+00:00","Z"),
    "count":len(items),
    "items":items,
})
print("EDITORIAL_QUEUE",len(items))
