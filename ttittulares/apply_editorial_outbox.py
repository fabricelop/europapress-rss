#!/usr/bin/env python3
from __future__ import annotations
import json, urllib.parse, urllib.request, io, sys
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
ERRORS=TT/"execution-errors.json"
DECISIONS=TT/"decisions.json"

def record_error(errors, event_id, phase, reason, now):
    errors.append({"at":now,"event_id":event_id,"phase":phase,"reason":str(reason)[:1000],
                   "remediation_prompt":f"Revisa TTiTTulares, fase {phase}, evento {event_id}: {str(reason)[:600]}. Corrige la causa y verifica el siguiente intento sin alterar las demás noticias."})

def load(p,d):
    try:return json.loads(p.read_text(encoding="utf-8"))
    except Exception:return d

def save(p,o):
    p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def normalize_variants(raw):
    """Read the historical Principal/A/B/C envelope for migration only."""
    if isinstance(raw, dict):
        raw=[{"label":label, **(value if isinstance(value,dict) else {"text":value})}
             for label,value in raw.items()]
    if not isinstance(raw,list):
        raise ValueError("variants inválidas")
    result=[]
    for value in raw:
        if not isinstance(value,dict):
            raise ValueError("variante no es objeto")
        result.append(dict(value))
    return result

def normalize_tweet(item):
    """Return the one canonical tweet, accepting the old four-variant shape."""
    raw=item.get("tweet")
    legacy=raw in (None,"")
    if legacy:
        variants=normalize_variants(item.get("variants") or [])
        # Historical compatibility is deterministic: A was the first complete
        # publishable tweet. Principal had no closer and is never selected.
        raw=next((v for v in variants if str(v.get("label") or v.get("key") or v.get("name") or "").upper()=="A"),None)
        if raw is None:
            raw=next((v for v in variants if str(v.get("remate") or "").strip()),None)
        if raw is None: raise ValueError("tweet único ausente")
    if isinstance(raw,str): raw={"text":raw}
    if not isinstance(raw,dict): raise ValueError("tweet inválido")
    tweet=dict(raw)
    text=str(tweet.get("text") or tweet.get("tweet_text") or "").strip()
    remate=str(tweet.get("remate") or "").strip()
    if not remate and "\n\n🌶️ " in text:
        remate="🌶️ "+text.rsplit("\n\n🌶️ ",1)[1].strip()
    if legacy and remate and not remate.startswith("🌶️ "):
        remate="🌶️ "+remate.lstrip()
    if not text or len(text)>280: raise ValueError("tweet vacío o >280")
    if "\\n" in text or "\\n" in remate: raise ValueError("saltos visibles prohibidos")
    if not remate.startswith("🌶️ ") or len(remate)<=3:
        raise ValueError("el remate único debe empezar por 🌶️ ")
    if legacy:
        principal=str((next((v for v in variants if str(v.get("label") or "").lower()=="principal"),{}) or {}).get("text") or "").strip()
        if text==remate and principal: text=principal+"\n\n"+remate
        elif principal and not text.startswith(principal+"\n\n"): text=principal+"\n\n"+remate
    if not text.endswith("\n\n"+remate):
        raise ValueError("el tweet debe terminar con dos saltos y su remate 🌶️")
    tweet={"text":text,"remate":remate,"url":"https://twitter.com/intent/tweet?text="+urllib.parse.quote(text,safe="")}
    return tweet

def validate_ready(payload):
    item=payload.get("prepared_item") or {}
    if not isinstance(item,dict): raise ValueError("prepared_item inválido")
    if not str(item.get("event_id") or ""): raise ValueError("prepared_item sin event_id")
    item["tweet"]=normalize_tweet(item)
    item.pop("variants",None)
    item.pop("primary",None)
    item.pop("alternatives",None)
    # La imagen es una capa paralela: nunca valida ni bloquea el READY.
    return item


def _image_url(image):
    return str((image or {}).get("url") or "").strip()


def _normalize_external_image(raw, item):
    image=dict(raw) if isinstance(raw,dict) else {}
    if isinstance(raw,str) and raw.strip():
        image["url"]=raw.strip()
    url=_image_url(image)
    if not url:
        return {}
    if not url.startswith("https://"):
        raise ValueError("la imagen de archivo debe usar HTTPS")
    image["url"]=url
    image["source"]=str(image.get("source") or _host(image.get("source_url") or url))
    source_url=str(image.get("source_url") or "").strip()
    if source_url and not source_url.startswith("https://"):
        raise ValueError("la página de origen debe usar HTTPS")
    image["source_url"]=source_url
    image["rights_status"]=str(image.get("rights_status") or "unverified")
    image["generated"]=False
    image["alt"]=str(image.get("alt") or item.get("title") or "Imagen del acontecimiento")
    return image


def _validate_raster_integrity(data, label):
    from PIL import Image, UnidentifiedImageError
    if len(data)<4096:
        raise ValueError(f"{label}: raster demasiado pequeño")
    try:
        with Image.open(io.BytesIO(data)) as probe:
            probe.verify()
        with Image.open(io.BytesIO(data)) as image:
            image.load();w,h=image.size
            if w<320 or h<180:
                raise ValueError(f"{label}: dimensiones insuficientes ({w}x{h})")
    except (UnidentifiedImageError,OSError,SyntaxError) as exc:
        raise ValueError(f"{label}: raster corrupto: {exc}")


def _materialize_ai_image(item):
    import base64, hashlib
    from PIL import Image, ImageOps
    ai=dict(item.get("ai_image") or {})
    if not ai or not _image_url(ai):
        return False
    eid=str(item.get("event_id") or "")
    rev=int(item.get("revision") or 1)
    attempt=int(item.get("ai_image_attempt") or ai.get("generation_attempt") or 1)
    guard=ai.get("context_guard") or {}
    if int(guard.get("version") or 0) not in {2,3}:
        raise ValueError("ai_image sin context_guard compatible")
    if str(guard.get("scope") or "")!="current_item_only":
        raise ValueError("ai_image sin scope current_item_only")
    guard_id=str(guard.get("event_id") or guard.get("trend_id") or "")
    if guard_id and guard_id!=eid:
        raise ValueError("ai_image pertenece a otro acontecimiento")
    if guard.get("revision") is not None and int(guard.get("revision"))!=rev:
        raise ValueError("ai_image pertenece a otra revisión")
    if ai.get("generated") is not True or str(ai.get("rights_status") or "")!="generated":
        raise ValueError("ai_image sin metadata generated")
    url=_image_url(ai)
    if url.startswith("data:image/"):
        header,payload=url.split(",",1)
        if ";base64" not in header:
            raise ValueError("data URL IA no base64")
        mime=header[5:].split(";",1)[0].casefold()
        if mime not in {"image/png","image/jpeg","image/webp"}:
            raise ValueError("mime IA no permitido")
        data=base64.b64decode(payload,validate=True)
        if len(data)>12_000_000:
            raise ValueError("raster IA demasiado grande")
        _validate_raster_integrity(data,"imagen IA")
        with Image.open(io.BytesIO(data)) as original:
            img=ImageOps.exif_transpose(original).convert("RGB")
            img.thumbnail((640,640),Image.Resampling.LANCZOS)
            out=io.BytesIO()
            for quality in (78,68,58,48):
                out.seek(0);out.truncate(0)
                img.save(out,format="JPEG",quality=quality,optimize=True)
                if len(out.getvalue())<=180_000:break
            data=out.getvalue()
        _validate_raster_integrity(data,"imagen IA normalizada")
        outdir=TT/"generated-images";outdir.mkdir(parents=True,exist_ok=True)
        filename=f"{eid}-r{rev}-ai{attempt}.jpg"
        (outdir/filename).write_bytes(data)
        ai["url"]=f"https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/{filename}"
        ai["source_url"]=f"https://github.com/fabricelop/europapress-rss/blob/main/ttittulares/generated-images/{filename}"
        ai["sha256"]=hashlib.sha256(data).hexdigest()
        ai["handoff"]="inline-outbox-materialized-by-actions"
    elif not url.startswith("https://"):
        raise ValueError("ai_image sin URL válida")
    ai["source"]=str(ai.get("source") or "TTiTTulares / ChatGPT")
    ai["rights_status"]="generated";ai["generated"]=True
    ai["alt"]=str(ai.get("alt") or item.get("title") or "Gag editorial de la noticia")
    ai["generation_attempt"]=attempt
    item["ai_image"]=ai
    item["ai_image_attempt"]=attempt
    item["ai_image_status"]="ready"
    item.pop("ai_image_failure_reason",None)
    return True


def normalize_image(item):
    """Compatibilidad: normaliza la imagen elegida sin eliminar IA/fallback."""
    raw=item.get("image")
    aliases={
        "image_url":"url","image_source":"source","image_source_url":"source_url",
        "image_alt":"alt","image_rights_status":"rights_status",
    }
    if isinstance(raw,dict):
        image=dict(raw)
    elif isinstance(raw,str) and raw.strip():
        image={"url":raw.strip()}
    else:
        image={}
    for old,new in aliases.items():
        value=item.get(old)
        if value not in (None,"") and not image.get(new):
            image[new]=value
    for old in aliases:
        item.pop(old,None)
    if not image:
        item.pop("image",None)
        return {}
    if image.get("generated"):
        url=_image_url(image)
        if url and not (url.startswith("https://") or url.startswith("data:image/")):
            raise ValueError("imagen IA seleccionada inválida")
        item["image"]=image
        return image
    image=_normalize_external_image(image,item)
    if image:item["image"]=image
    else:item.pop("image",None)
    return image


def validate_image(item):
    image=normalize_image(item)
    if not image:return
    url=_image_url(image)
    if not (url.startswith("https://") or url.startswith("data:image/")):
        raise ValueError("imagen seleccionada sin URL válida")


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


def _valid_external_image(url,referer=""):
    try:
        headers={"User-Agent":"Mozilla/5.0 (compatible; TTiTTularesImage/3.0)","Accept":"image/*"}
        if referer: headers["Referer"]=referer
        req=urllib.request.Request(url,headers=headers)
        with urllib.request.urlopen(req,timeout=10) as r:
            if not str(r.geturl()).startswith("https://"): return False
            if not str(r.headers.get("content-type") or "").lower().startswith("image/"): return False
            data=r.read(12*1024*1024+1)
        if len(data)<4096 or len(data)>12*1024*1024:return False
        _validate_raster_integrity(data,"fallback")
        return True
    except Exception:
        return False


def _fetch_meta_image(page_url):
    try:
        req=urllib.request.Request(page_url,headers={"User-Agent":"Mozilla/5.0 (compatible; TTiTTularesImage/3.0)","Accept":"text/html,application/xhtml+xml"})
        with urllib.request.urlopen(req,timeout=10) as r:
            ctype=str(r.headers.get("content-type") or "").lower()
            if "html" not in ctype:return None
            final=r.geturl();raw=r.read(1500000)
        parser=_MetaImageParser();parser.feed(raw.decode("utf-8","ignore"))
        seen=set()
        for value in parser.images:
            url=urllib.parse.urljoin(final,value)
            if not url.startswith("https://") or url in seen:continue
            seen.add(url)
            if _valid_external_image(url,final):return url
    except Exception:return None
    return None


def _recover_fallback_image(item,row,events):
    current=item.get("fallback_image") or {}
    if _image_url(current):
        try:
            image=_normalize_external_image(current,item)
            if _valid_external_image(image["url"],image.get("source_url") or ""):
                item["fallback_image"]=image;item["fallback_image_status"]="ready";return True
        except Exception:
            pass
    pages=[];seen=set()
    def add(url,source=""):
        url=str(url or "").strip()
        if not url.startswith("https://") or url in seen:return
        seen.add(url);pages.append((url,source or _host(url)))
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
        item["fallback_image"]={"url":img,"source":source,"source_url":page,"rights_status":"unverified","generated":False,"alt":str(item.get("title") or "Imagen de archivo relacionada con la noticia")}
        item["fallback_image_status"]="ready";item["fallback_image_search_attempted_at"]=datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
        item.pop("fallback_image_failure_reason",None);return True
    item["fallback_image_status"]="none";item["fallback_image_search_attempted_at"]=datetime.now(timezone.utc).isoformat().replace("+00:00","Z")
    item["fallback_image_failure_reason"]="No se encontró una imagen HTTPS verificable en las páginas de las fuentes del acontecimiento."
    return False


def _select_image(item):
    ai_ready=str(item.get("ai_image_status") or "")=="ready" and bool(_image_url(item.get("ai_image")))
    fallback_ready=str(item.get("fallback_image_status") or "")=="ready" and bool(_image_url(item.get("fallback_image")))
    choice=str(item.get("image_choice") or "")
    if choice=="fallback" and fallback_ready:
        item["image"]=dict(item["fallback_image"]);item["image_choice"]="fallback";item["image_status"]="ready"
    elif ai_ready:
        item["image"]=dict(item["ai_image"]);item["image_choice"]="ai";item["image_status"]="ready"
    elif fallback_ready:
        item["image"]=dict(item["fallback_image"]);item["image_choice"]="fallback";item["image_status"]="ready"
    else:
        item.pop("image",None);item["image_choice"]="none";item["image_status"]="none"
    item["image_pending"]=False
    item["image_app_available"]=bool((item.get("image") or {}).get("url"))
    item["image_delivery"]="app" if item["image_app_available"] else "none"


def _finish_archive_image(item,row,events):
    """Best-effort AI materialization + archive fallback. Never raises to block READY."""
    try:
        if item.get("ai_image"):
            _materialize_ai_image(item)
        elif not item.get("ai_image_status"):
            item["ai_image_status"]="failed"
            item["ai_image_failure_reason"]="No se recibió imagen IA en este intento."
    except Exception as exc:
        item["ai_image_status"]="failed"
        item["ai_image_failure_reason"]=str(exc)[:500]
        # Keep a previous usable AI on image-only refresh failures.
        if not _image_url(item.get("ai_image")):
            item.pop("ai_image",None)
    try:
        if str(item.get("fallback_image_status") or "") not in {"ready","none"}:
            _recover_fallback_image(item,row,events)
    except Exception as exc:
        item["fallback_image_status"]="none";item["fallback_image_failure_reason"]=str(exc)[:500]
    _select_image(item)
    item["image_strategy"]="ai_plus_fallback"
    item.pop("ai_image_regenerate_requested",None)
    item.pop("ai_image_regenerate_requested_at",None)
    return item["image_app_available"]


def _enrich_prepared_images(p,q,events):
    """Completa únicamente el fallback pendiente sin alterar READY ni la IA."""
    changed=False
    rows={(str(x.get("event_id") or ""),int(x.get("revision") or 1)):x for x in q.get("items",[]) or []}
    for item in p.get("items",[]) or []:
        if str(item.get("fallback_image_status") or "") in {"ready","none"}:continue
        eid=str(item.get("event_id") or "");revision=int(item.get("revision") or 1)
        before=json.dumps(item,ensure_ascii=False,sort_keys=True)
        try:_recover_fallback_image(item,rows.get((eid,revision),{}),events)
        except Exception as exc:
            item["fallback_image_status"]="none";item["fallback_image_failure_reason"]=str(exc)[:500]
        _select_image(item)
        changed=changed or before!=json.dumps(item,ensure_ascii=False,sort_keys=True)
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
            "with_image":True,"image_mode":"ai_plus_fallback",
            "image_instruction":"Intenta una sola imagen IA editorial rápida y conserva además una imagen real/fallback de las fuentes. Ninguna imagen puede bloquear READY.",
        })
    # La imagen se resuelve de forma determinista al aplicar el READY; nunca crea IMAGE_RETRY.
    active.sort(key=lambda x:(0 if x.get("selection_mode")=="IMAGE_RETRY" else 1, str(x.get("selected_at") or "")))
    path=TT/"editorial-queue.json"
    old=load(path,{})
    if old.get("items")==active and int(old.get("count") or 0)==len(active):
        return False
    save(path,{
        "project":"TTiTTulares","updated_at":datetime.now(timezone.utc).isoformat().replace("+00:00","Z"),
        "count":len(active),"items":active
    })
    return True

def resolve_duplicate(payload, eid, previous, queue, decisions):
    """A reviewed duplicate is terminal only against an actual user decision."""
    if previous is not None:
        raise ValueError("un duplicado no puede ocultar una noticia ya materializada")
    original_id=str(payload.get("duplicate_of_event_id") or "").strip()
    reason=str(payload.get("reason") or "").strip()
    if not original_id or original_id==eid or len(reason)<12:
        raise ValueError("referencia o justificación de duplicidad inválida")
    original=next((x for x in queue.get("items",[]) if str(x.get("event_id") or "")==original_id),None)
    decision=next((x for x in reversed(decisions.get("items",[]))
                   if str(x.get("event_id") or "")==original_id),None)
    if original is None:
        raise ValueError("el acontecimiento original no existe en la cola")
    state=str((decision or {}).get("status") or original.get("status") or "").upper()
    if state not in {"PUBLISHED","DISMISSED"}:
        raise ValueError("la noticia original no consta publicada ni descartada por el usuario")
    if state=="PUBLISHED" and payload.get("no_material_update") is not True:
        raise ValueError("falta confirmar explícitamente ausencia de novedad material")
    return ("SKIPPED_DUPLICATE" if state=="PUBLISHED" else "DISMISSED"),original_id,reason


def selftest_duplicate():
    queue={"items":[{"event_id":"old","status":"PUBLISHED"},{"event_id":"dismissed","status":"DISMISSED"}]}
    decisions={"items":[{"event_id":"old","status":"published"},{"event_id":"dismissed","status":"dismissed"}]}
    payload={"duplicate_of_event_id":"old","reason":"Mismo hecho sin información adicional","no_material_update":True}
    assert resolve_duplicate(payload,"new",None,queue,decisions)[0]=="SKIPPED_DUPLICATE"
    assert resolve_duplicate({**payload,"duplicate_of_event_id":"dismissed"},"new",None,queue,decisions)[0]=="DISMISSED"
    for invalid in ({**payload,"no_material_update":False},{**payload,"duplicate_of_event_id":"unknown"}):
        try: resolve_duplicate(invalid,"new",None,queue,decisions)
        except ValueError: pass
        else: raise AssertionError("duplicado inseguro aceptado")
    try: resolve_duplicate(payload,"new",{"event_id":"new"},queue,decisions)
    except ValueError: pass
    else: raise AssertionError("se ocultó un READY")
    print("OUTBOX_DUPLICATE_SELFTEST_OK")
    return 0


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
            previous=next((x for x in p.get("items",[]) if str(x.get("event_id") or "")==eid and int(x.get("revision") or 1)==rev),None)
            image_retry=row.get("status")=="READY" and previous is not None
            if str(row.get("status") or "") not in {"PROCESSING","PROBLEMATIC"} and not image_retry:
                path.unlink(); continue
            st=str(payload.get("status") or "")
            if image_retry:
                if st!="ready": raise ValueError("image retry no puede cambiar el estado READY")
                incoming=payload.get("prepared_item") or {}
                patch_keys={"ai_image","ai_image_status","ai_image_attempt","ai_image_failure_reason",
                            "fallback_image","fallback_image_status","fallback_image_failure_reason",
                            "image_choice","image","image_status","image_pending"}
                item={**previous,**{k:v for k,v in incoming.items() if k in patch_keys}}
                item["tweet"]=previous.get("tweet")
                payload["prepared_item"]=item
            if st=="ready":
                item=validate_ready(payload)
                # IA y fallback se procesan en best-effort y jamás bloquean READY.
                _finish_archive_image(item,row,events)
                p["items"]=[x for x in p.get("items",[]) if str(x.get("event_id") or "")!=eid]
                p["items"].append(item);p["updated_at"]=item.get("prepared_at") or now
                if image_retry:
                    processed.append(eid);path.unlink();continue
                previous_attempts=int(row.get("problematic_attempts") or (1 if str(row.get("status") or "")=="PROBLEMATIC" else 0))
                if previous_attempts:
                    item.setdefault("problematic_attempts_before_ready",previous_attempts)
                row["status"]="READY";row["delivered_at"]=item.get("prepared_at") or now;row["delivery_confirmation"]="prepared_web"
                row.pop("problem_reason",None);row.pop("problematic_at",None);row.pop("problematic_attempts",None);row.pop("verification_hint",None);row.pop("verification_hint_at",None);row.pop("user_validated",None);row.pop("user_validated_at",None);row.pop("user_validation_source",None);row.pop("user_validation_version",None)
            elif st=="duplicate":
                target,original_id,reason=resolve_duplicate(
                    payload,eid,previous,q,load(DECISIONS,{"items":[]}))
                row["status"]=target
                row["reconciled_from_event_id"]=original_id
                row["reconciliation_reason"]=reason
                row["reconciled_at"]=now
            elif st=="problematic":
                reason=str(payload.get("problem_reason") or "").strip()
                if not reason: raise ValueError("problematic sin razón")
                attempts=int(row.get("problematic_attempts") or 0)+1
                row["status"]="PROBLEMATIC";row["problematic_at"]=now;row["problem_reason"]=reason;row["problematic_attempts"]=attempts
                # Check/validación explícita autoriza un único reintento.
                if bool(row.get("user_validated")):
                    row["user_validation_consumed_at"]=now
                    row["user_validation_consumed_version"]=int(row.get("user_validation_version") or 1)
                    row["user_validated"]=False
                    row.pop("user_validated_at",None)
            else: raise ValueError("status inválido")
            processed.append(eid);path.unlink()
        except Exception as exc:
            errors.append(f"{path.name}: {type(exc).__name__}: {exc}")
            print("ERROR",errors[-1])
            ledger=load(ERRORS,{"items":[]})
            record_error(ledger.setdefault("items",[]),path.stem,"outbox",errors[-1],now)
            ledger["items"]=ledger["items"][-200:];save(ERRORS,ledger)
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
    # Un outbox defectuoso queda para reparación; los demás ya se aplicaron.
    return 0

def selftest_images():
    current={"prepared_item":{"event_id":"selftest","revision":1,"tweet":{
        "text":"Titular de prueba\n\n🌶️ Remate único.","remate":"🌶️ Remate único."
    }}}
    normalized=validate_ready(current)
    assert normalized["tweet"]["text"]=="Titular de prueba\n\n🌶️ Remate único."
    assert "variants" not in normalized
    legacy={"prepared_item":{"event_id":"legacy","revision":1,"variants":[
        {"label":"Principal","text":"Titular antiguo","remate":""},
        {"label":"A","text":"Titular antiguo\n\n🌶️ Primer remate","remate":"🌶️ Primer remate"},
        {"label":"B","text":"Titular antiguo\n\n🌶️ Segundo remate","remate":"🌶️ Segundo remate"},
        {"label":"C","text":"Titular antiguo\n\n🌶️ Tercer remate","remate":"🌶️ Tercer remate"},
    ]}}
    migrated=validate_ready(legacy)
    assert migrated["tweet"]["remate"]=="🌶️ Primer remate"
    assert "variants" not in migrated
    flat={"title":"Prueba","image":"https://cdn.example.test/photo.jpg","image_source":"Fuente","image_source_url":"https://example.test/story"}
    image=normalize_image(flat)
    assert image["url"]=="https://cdn.example.test/photo.jpg"
    assert image["source"]=="Fuente" and image["rights_status"]=="unverified"
    assert "image_url" not in flat and isinstance(flat["image"],dict)
    dual={"event_id":"dual","revision":1,"title":"Prueba",
          "ai_image":{"url":"https://example.test/generated.jpg","source":"TTiTTulares / ChatGPT","rights_status":"generated","generated":True,
                      "context_guard":{"version":3,"event_id":"dual","revision":1,"scope":"current_item_only"}},
          "ai_image_status":"ready",
          "fallback_image":{"url":"https://example.test/archive.jpg","source":"Fuente","source_url":"https://example.test/story","rights_status":"unverified","generated":False},
          "fallback_image_status":"ready"}
    _select_image(dual)
    assert dual["image_choice"]=="ai" and dual["image"]["generated"] is True
    dual["image_choice"]="fallback";_select_image(dual)
    assert dual["image_choice"]=="fallback" and dual["image"]["generated"] is False
    print("DUAL_IMAGE_SELFTEST_OK")
    return 0

if "--selftest-images" in sys.argv:
    raise SystemExit(selftest_images())
if "--selftest-duplicate" in sys.argv:
    raise SystemExit(selftest_duplicate())
if __name__=="__main__":
    raise SystemExit(main())
