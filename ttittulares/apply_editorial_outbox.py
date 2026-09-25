#!/usr/bin/env python3
from __future__ import annotations
import json, urllib.parse, urllib.request, base64, io
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
TT=ROOT/"ttittulares"
TG=ROOT/"telegram"
OUTBOX=TT/"editorial-outbox"
QUEUE=TG/"editorial-processing.json"
PREP=TT/"prepared.json"
STATUS=TT/"status.json"
EVENTS=TG/"events.json"

def load(p,d):
    try:return json.loads(p.read_text(encoding="utf-8"))
    except Exception:return d

def save(p,o):
    p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def validate_ready(payload):
    item=payload.get("prepared_item") or {}
    if not str(item.get("event_id") or ""): raise ValueError("prepared_item sin event_id")
    variants=item.get("variants") or []
    labels=[str(v.get("label") or v.get("name") or "") for v in variants]
    if labels != ["Principal","A","B","C"]:
        raise ValueError("variants debe ser Principal/A/B/C")
    for v,label in zip(variants,labels):
        v["label"]=label
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
        v["url"]=expected
        v.pop("tweet_url",None)
    validate_image(item)
    return item


def _validate_raster_integrity(data: bytes, label: str):
    from PIL import Image, ImageStat, UnidentifiedImageError
    if len(data) < 4096: raise ValueError(f"{label}: imagen raster demasiado pequeña o inválida")
    try:
        with Image.open(io.BytesIO(data)) as probe: probe.verify()
        with Image.open(io.BytesIO(data)) as image:
            image.load(); w,h=image.size
            if w < 600 or h < 360: raise ValueError(f"{label}: dimensiones insuficientes ({w}x{h})")
            if "A" in image.getbands():
                alpha=image.getchannel("A").resize((128,128)); vals=list(alpha.getdata())
                if sum(1 for v in vals if v<16)/max(1,len(vals)) > .25: raise ValueError(f"{label}: demasiada transparencia")
            rgb=image.convert("RGB"); rgb.thumbnail((256,256)); pixels=list(rgb.getdata())
            near=lambda p:p[0]<12 and p[1]<12 and p[2]<12
            if pixels and sum(1 for p in pixels if near(p))/len(pixels) > .60: raise ValueError(f"{label}: imagen anómalamente negra")
            gray=rgb.convert("L"); stat=ImageStat.Stat(gray)
            if stat.stddev and stat.stddev[0] < 4: raise ValueError(f"{label}: imagen prácticamente uniforme")
    except (UnidentifiedImageError,OSError,SyntaxError) as exc: raise ValueError(f"{label}: raster corrupto o truncado: {exc}")


def validate_image(item):
    image=item.get("image") or {}
    if not image: return
    if not image.get("generated"): return
    if image.get("rights_status")!="generated" or image.get("source")!="TTiTTulares / ChatGPT":
        raise ValueError("metadatos de imagen generada inválidos")
    checks=image.get("style_check") or {}
    required=["reviewed_after_generation","single_narrative_scene","visual_gag_without_text","no_infographic_layout","no_diagram_arrows_or_connectors","no_ui_or_scoreboard_layout","low_text","depth_lighting_texture"]
    if image.get("style_version")!="editorial-scene-v2-cleveland" or not all(checks.get(k) is True for k in required):
        raise ValueError("imagen generada sin control visual editorial-scene-v2-cleveland completo")
    url=str(image.get("url") or "")
    prefix="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/"
    if url.startswith("data:image/"):
        header,payload=url.split(",",1); mime=header[5:].split(";",1)[0].casefold()
        if ";base64" not in header or mime not in {"image/png","image/webp","image/jpeg"}: raise ValueError("data URL raster inválida")
        _validate_raster_integrity(base64.b64decode(payload,validate=True),"imagen raster inline"); return
    if not url.startswith(prefix): raise ValueError("URL raw de imagen generada inválida")
    filename=url[len(prefix):]
    if "/" in filename or ".." in filename or Path(filename).suffix.casefold() not in {".png",".webp",".jpg",".jpeg"}: raise ValueError("ruta de imagen generada inválida")
    fp=TT/"generated-images"/filename
    if not fp.exists(): raise ValueError("fichero de imagen generada inexistente en main")
    _validate_raster_integrity(fp.read_bytes(),f"imagen generada {filename}")


class _MetaImageParser(HTMLParser):
    def __init__(self):
        super().__init__(); self.images=[]
    def handle_starttag(self,tag,attrs):
        if tag.lower()!="meta": return
        a={str(k).lower():str(v or "") for k,v in attrs}
        key=(a.get("property") or a.get("name") or "").lower()
        if key in {"og:image","og:image:secure_url","twitter:image","twitter:image:src"} and a.get("content"):
            self.images.append(a["content"].strip())

def _host(url):
    try:return urllib.parse.urlparse(url).hostname or "Fuente"
    except Exception:return "Fuente"

def _fetch_meta_image(page_url):
    try:
        req=urllib.request.Request(page_url,headers={"User-Agent":"Mozilla/5.0 (compatible; TTiTTularesImage/1.0)","Accept":"text/html,application/xhtml+xml"})
        with urllib.request.urlopen(req,timeout=4) as r:
            ctype=str(r.headers.get("content-type") or "").lower()
            if "html" not in ctype:return None
            final=r.geturl(); raw=r.read(900000)
        parser=_MetaImageParser(); parser.feed(raw.decode("utf-8","ignore"))
        for value in parser.images:
            url=urllib.parse.urljoin(final,value)
            if not url.startswith("https://"):continue
            try:
                probe=urllib.request.Request(url,headers={"User-Agent":"Mozilla/5.0 (compatible; TTiTTularesImage/1.0)","Accept":"image/*","Referer":final,"Range":"bytes=0-2047"})
                with urllib.request.urlopen(probe,timeout=3) as ir:
                    if str(ir.headers.get("content-type") or "").lower().startswith("image/"):
                        ir.read(32); return url
            except Exception:
                continue
    except Exception:
        return None
    return None

def _recover_image(item,row,events):
    image=item.get("image") or {}
    if str(image.get("url") or "").strip():
        item["image_search_status"]="found"; return True
    pages=[]; seen=set()
    def add(url,source=""):
        url=str(url or "").strip()
        if not url.startswith(("http://","https://")) or url in seen:return
        seen.add(url); pages.append((url,source or _host(url)))
    add(item.get("url") or row.get("url"),"")
    eid=str(item.get("event_id") or row.get("event_id") or "")
    parent=str(row.get("parent_event_id") or "")
    ev=next((e for e in events.get("events",[]) or [] if str(e.get("id") or e.get("event_id") or "") in {eid,parent}),None)
    if ev:
        wanted=set(str(x) for x in (row.get("sources") or []))
        apps=sorted(ev.get("appearances") or [],key=lambda a:(0 if str(a.get("source") or "") in wanted else 1,1 if "news.google.com" in str(a.get("url") or "") else 0))
        for a in apps:add(a.get("url"),str(a.get("source") or ""))
    for page,source in pages[:4]:
        img=_fetch_meta_image(page)
        if not img:continue
        item["image"]={"url":img,"source":source,"source_url":page,"rights_status":"unverified","alt":str(item.get("title") or "Imagen relacionada con la noticia")}
        item["image_search_status"]="found"; item["image_search_attempted_at"]=datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
        item.pop("image_note",None); return True
    item["image_search_status"]="not_found"; item["image_search_attempted_at"]=datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
    item["image_note"]="No se encontró una imagen verificable en los metadatos de la noticia ni de sus fuentes alternativas."
    return False

def _enrich_prepared_images(p,q,events):
    changed=False; now=datetime.now(timezone.utc)
    rows=q.get("items",[]) or []
    for item in p.get("items",[]) or []:
        if str((item.get("image") or {}).get("url") or item.get("image_url") or "").strip():continue
        attempted=item.get("image_search_attempted_at")
        if attempted:
            try:
                prev=datetime.fromisoformat(str(attempted).replace("Z","+00:00"))
                if (now-prev).total_seconds()<21600:continue
            except Exception:pass
        eid=str(item.get("event_id") or "")
        row=next((x for x in reversed(rows) if str(x.get("event_id") or "")==eid),None) or {"event_id":eid,"url":item.get("url") or "","sources":item.get("sources_at_draft") or [],"with_image":True}
        if not bool(row.get("with_image",True)):continue
        _recover_image(item,row,events); changed=True
    return changed


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
            "with_image":True,"image_mode":"generated_gag_or_archive_fallback",
            "image_instruction":"Genera por defecto una imagen editorial ORIGINAL raster con gag visual específico, usando exactamente la línea editorial-scene-v2-cleveland de TTendencias. Una sola escena narrativa, gag comprensible sin texto, detalle medio y composición simple. Si la noticia implica víctimas, abusos, tragedia, sufrimiento o el gag no es apropiado, NO hagas humor: usa una imagen existente del acontecimiento, priorizando fuente oficial/primaria y después medios fiables.",
        })
    active.sort(key=lambda x:str(x.get("selected_at") or ""))
    save(TT/"editorial-queue.json",{
        "project":"TTiTTulares","updated_at":datetime.now(timezone.utc).isoformat().replace("+00:00","Z"),
        "count":len(active),"items":active
    })

def main():
    q=load(QUEUE,{"items":[]})
    p=load(PREP,{"project":"TTiTTulares","items":[]})
    events=load(EVENTS,{"events":[]})
    files=sorted(OUTBOX.glob("*.json")) if OUTBOX.exists() else []
    if not files:
        changed=_enrich_prepared_images(p,q,events)
        if changed: save(PREP,p)
        sync_compact(q); print("Sin outbox pendiente; imágenes recuperadas" if changed else "Sin outbox pendiente"); return 0
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
            if str(row.get("status") or "") not in {"PROCESSING","PROBLEMATIC"}:
                path.unlink(); continue
            st=str(payload.get("status") or "")
            if st=="ready":
                item=validate_ready(payload)
                if bool(row.get("with_image", True)):
                    image=item.get("image") or {}
                    if image.get("generated"):
                        validate_image(item)
                        item["image_search_status"]="generated"
                    elif not str(image.get("url") or "").strip():
                        _recover_image(item,row,events)
                p["items"]=[x for x in p.get("items",[]) if str(x.get("event_id") or "")!=eid]
                p["items"].append(item);p["updated_at"]=item.get("prepared_at") or now
                previous_attempts=int(row.get("problematic_attempts") or (1 if str(row.get("status") or "")=="PROBLEMATIC" else 0))
                if previous_attempts:
                    item.setdefault("problematic_attempts_before_ready",previous_attempts)
                row["status"]="READY";row["delivered_at"]=item.get("prepared_at") or now;row["delivery_confirmation"]="prepared_web"
                row.pop("problem_reason",None);row.pop("problematic_at",None);row.pop("problematic_attempts",None);row.pop("verification_hint",None);row.pop("verification_hint_at",None);row.pop("user_validated",None);row.pop("user_validated_at",None);row.pop("user_validation_source",None);row.pop("user_validation_version",None)
            elif st=="problematic":
                reason=str(payload.get("problem_reason") or "").strip()
                if not reason: raise ValueError("problematic sin razón")
                attempts=int(row.get("problematic_attempts") or 0)+1
                row["status"]="PROBLEMATIC";row["problematic_at"]=now;row["problem_reason"]=reason;row["problematic_attempts"]=attempts
            else: raise ValueError("status inválido")
            processed.append(eid);path.unlink()
        except Exception as exc:
            errors.append(f"{path.name}: {type(exc).__name__}: {exc}")
            print("ERROR",errors[-1])
    _enrich_prepared_images(p,q,events)
    q["updated_at"]=now
    save(QUEUE,q);save(PREP,p);sync_compact(q)
    st=load(STATUS,{})
    st["updated_at"]=now
    active=[x for x in q.get("items",[]) if str(x.get("status") or "")=="PROCESSING"]
    st["processing_count"]=len(active)
    st["processing_items"]=active
    problematic=[]
    for x in q.get("items",[]) or []:
        if str(x.get("status") or "")!="PROBLEMATIC": continue
        problematic.append({
            "event_id":x.get("event_id"),"title":x.get("title") or "","url":x.get("url") or "",
            "selected_at":x.get("selected_at"),"problematic_at":x.get("problematic_at"),
            "problem_reason":x.get("problem_reason") or "","problematic_attempts":int(x.get("problematic_attempts") or 1),
            "user_validated":bool(x.get("user_validated")),"user_validated_at":x.get("user_validated_at"),
            "revision":int(x.get("revision") or 1),
            "source_count":int(x.get("source_count") or 0),"sources":x.get("sources") or [],
        })
    problematic.sort(key=lambda x:str(x.get("problematic_at") or x.get("selected_at") or ""),reverse=True)
    st["problematic_count"]=len(problematic)
    st["problematic_items"]=problematic
    st["ready_count"]=len(p.get("items",[]))
    save(STATUS,st)
    print(json.dumps({"processed":processed,"errors":errors},ensure_ascii=False))
    return 0
if __name__=="__main__":
    raise SystemExit(main())

