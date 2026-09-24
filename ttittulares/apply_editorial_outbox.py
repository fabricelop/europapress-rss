#!/usr/bin/env python3
from __future__ import annotations
import json, urllib.parse
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
TT=ROOT/"ttittulares"
TG=ROOT/"telegram"
OUTBOX=TT/"editorial-outbox"
QUEUE=TG/"editorial-processing.json"
PREP=TT/"prepared.json"
STATUS=TT/"status.json"

def load(p,d):
    try:return json.loads(p.read_text(encoding="utf-8"))
    except Exception:return d

def save(p,o):
    p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def validate_ready(payload):
    item=payload.get("prepared_item") or {}
    if not str(item.get("event_id") or ""): raise ValueError("prepared_item sin event_id")
    variants=item.get("variants") or []
    if [str(v.get("label")) for v in variants] != ["Principal","A","B","C"]:
        raise ValueError("variants debe ser Principal/A/B/C")
    for i,v in enumerate(variants):
        text=str(v.get("text") or "")
        remate=str(v.get("remate") or "")
        if not text or len(text)>280: raise ValueError("text vacío o >280")
        if "\\n" in text or "\\n" in remate: raise ValueError("saltos visibles prohibidos")
        if i==0:
            if remate!="": raise ValueError("Principal remate no vacío")
        else:
            if not remate.startswith("🌶️ "): raise ValueError("remate sin guindilla")
            principal=str(variants[0].get("text") or "")
            if text != principal+"\n\n"+remate: raise ValueError("text alternativo no coincide")
        expected="https://twitter.com/intent/tweet?text="+urllib.parse.quote(text,safe="")
        if str(v.get("url") or "") != expected: raise ValueError("intent incorrecto")
    return item

def sync_compact(q):
    active=[]
    for x in q.get("items",[]) or []:
        if str(x.get("status") or "")!="PROCESSING": continue
        active.append({
            "event_id":x.get("event_id"),"title":x.get("title") or "","url":x.get("url") or "",
            "sources":x.get("sources") or [],"source_count":int(x.get("source_count") or 0),
            "selected_at":x.get("selected_at"),"selection_mode":x.get("selection_mode") or "",
            "revision":int(x.get("revision") or 1),
            "rewrite_request":x.get("rewrite_request") or x.get("rewrite_instruction") or "",
            "parent_event_id":x.get("parent_event_id"),"update_context":x.get("update_context"),
            "with_image":True,"image_mode":"existing_web_image",
            "image_instruction":"Busca una imagen existente y relevante al hecho en una fuente oficial/primaria o medio fiable. Haz al menos una búsqueda específica y, si falla, una segunda vía u og:image de una fuente usada. No generes imágenes. Guarda URL directa, fuente, página de origen y rights_status. Si no encuentras una adecuada, deja constancia explícita.",
        })
    active.sort(key=lambda x:str(x.get("selected_at") or ""))
    save(TT/"editorial-queue.json",{
        "project":"TTiTTulares","updated_at":datetime.now(timezone.utc).isoformat().replace("+00:00","Z"),
        "count":len(active),"items":active
    })

def main():
    q=load(QUEUE,{"items":[]})
    p=load(PREP,{"project":"TTiTTulares","items":[]})
    files=sorted(OUTBOX.glob("*.json")) if OUTBOX.exists() else []
    if not files:
        sync_compact(q); print("Sin outbox pendiente"); return 0
    now=datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
    errors=[];processed=[]
    for path in files:
        try:
            payload=load(path,None)
            if not isinstance(payload,dict): raise ValueError("payload inválido")
            eid=str(payload.get("event_id") or "")
            rev=int(payload.get("revision") or 1)
            row=next((x for x in q.get("items",[]) if str(x.get("event_id") or "")==eid and int(x.get("revision") or 1)==rev),None)
            if row is None:
                path.unlink(); continue
            if str(row.get("status") or "")!="PROCESSING":
                path.unlink(); continue
            st=str(payload.get("status") or "")
            if st=="ready":
                item=validate_ready(payload)
                if bool(row.get("with_image", True)):
                    image=item.get("image") or {}
                    if str(image.get("url") or "").strip():
                        item["image_search_status"]=item.get("image_search_status") or "found"
                    else:
                        item["image_search_status"]="not_found"
                        item["image_note"]=item.get("image_note") or "Sin imagen adecuada encontrada tras la búsqueda editorial."
                p["items"]=[x for x in p.get("items",[]) if str(x.get("event_id") or "")!=eid]
                p["items"].append(item);p["updated_at"]=item.get("prepared_at") or now
                row["status"]="READY";row["delivered_at"]=item.get("prepared_at") or now;row["delivery_confirmation"]="prepared_web"
                row.pop("problem_reason",None);row.pop("problematic_at",None)
            elif st=="problematic":
                reason=str(payload.get("problem_reason") or "").strip()
                if not reason: raise ValueError("problematic sin razón")
                row["status"]="PROBLEMATIC";row["problematic_at"]=now;row["problem_reason"]=reason
            else: raise ValueError("status inválido")
            processed.append(eid);path.unlink()
        except Exception as exc:
            errors.append(f"{path.name}: {type(exc).__name__}: {exc}")
            print("ERROR",errors[-1])
    q["updated_at"]=now
    save(QUEUE,q);save(PREP,p);sync_compact(q)
    st=load(STATUS,{})
    st["updated_at"]=now
    active=[x for x in q.get("items",[]) if str(x.get("status") or "")=="PROCESSING"]
    st["processing_count"]=len(active)
    st["processing_items"]=active
    st["ready_count"]=len(p.get("items",[]))
    save(STATUS,st)
    print(json.dumps({"processed":processed,"errors":errors},ensure_ascii=False))
    return 0 if not errors else 1
if __name__=="__main__":
    raise SystemExit(main())
