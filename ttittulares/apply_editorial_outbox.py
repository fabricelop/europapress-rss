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

def record_error(errors, event_id, phase, reason, now):
    errors.append({"at":now,"event_id":event_id,"phase":phase,"reason":str(reason)[:1000],
                   "remediation_prompt":f"Revisa TTiTTulares, fase {phase}, evento {event_id}: {str(reason)[:600]}. Corrige la causa y verifica el siguiente intento sin alterar las demás noticias."})

def load(p,d):
    try:return json.loads(p.read_text(encoding="utf-8"))
    except Exception:return d

def save(p,o):
    p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def normalize_variants(raw):
    """Accept the compact outbox forms and return the canonical four records.

    Work comments have historically represented variants either as a list of
    records or as a label-to-content object.  This is a transport detail, not
    an editorial distinction: the web state always stores four records.
    """
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

def validate_ready(payload):
    item=payload.get("prepared_item") or {}
    if not isinstance(item,dict): raise ValueError("prepared_item inválido")
    if not str(item.get("event_id") or ""): raise ValueError("prepared_item sin event_id")
    variants=normalize_variants(item.get("variants") or [])
    labels=[str(v.get("label") or v.get("key") or v.get("name") or "") for v in variants]
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
            principal=str(variants[0].get("text") or "")
            # A/B/C may arrive as their compact remate, or as the full text.
            # Canonicalize the envelope without changing the written remate.
            inferred_remate=False
            if not remate and text.startswith(principal+"\n\n"):
                remate=text[len(principal)+2:]
                inferred_remate=True
            elif not remate:
                remate=text
                inferred_remate=True
            if not remate.startswith("🌶️ "):
                remate="🌶️ "+remate.lstrip()
            v["remate"]=remate
            expected_text=principal+"\n\n"+remate
            # Tolerancia de transporte: algunos ejecutores envían en A/B/C solo el
            # remate aunque `remate` sea correcto. Normalízalo aquí sin inventar
            # contenido. Cualquier otra discrepancia sigue siendo un error real.
            if text == remate:
                text=expected_text
                v["text"]=text
            elif inferred_remate:
                text=expected_text
                v["text"]=text
            elif text != expected_text:
                raise ValueError("text alternativo no coincide")
        v["text"]=text
        expected="https://twitter.com/intent/tweet?text="+urllib.parse.quote(text,safe="")
        v["url"]=expected
        v.pop("tweet_url",None)
    item["variants"]=variants
    normalize_image(item)
    validate_image(item)
    return item


def normalize_image(item):
    """Normaliza formatos históricos y conserva solo imágenes reales externas."""
    raw=item.get("image")
    image=dict(raw) if isinstance(raw,dict) else {}
    if isinstance(raw,str) and raw.strip():
        image["url"]=raw.strip()
    aliases={
        "image_url":"url","image_source":"source","image_source_url":"source_url",
        "image_alt":"alt","image_rights_status":"rights_status",
    }
    for old,new in aliases.items():
        value=item.get(old)
        if value not in (None,"") and not image.get(new):
            image[new]=value
    url=str(image.get("url") or "").strip()
    for old in aliases:
        item.pop(old,None)
    if not url:
        item.pop("image",None)
        return {}
    if not url.startswith("https://"):
        raise ValueError("la imagen debe usar HTTPS")
    if image.get("generated") or str(image.get("rights_status") or "").lower()=="generated" or "chatgpt" in str(image.get("source") or "").lower():
        raise ValueError("las imágenes generadas por IA no están permitidas")
    image["url"]=url
    image["source"]=str(image.get("source") or _host(image.get("source_url") or url))
    source_url=str(image.get("source_url") or "").strip()
    if source_url and not source_url.startswith("https://"):
        raise ValueError("la página de origen debe usar HTTPS")
    image["source_url"]=source_url
    image["rights_status"]=str(image.get("rights_status") or "unverified")
    image["alt"]=str(image.get("alt") or item.get("title") or "Imagen del acontecimiento")
    for key in ("generated","style_version","style_check","handoff"):
        image.pop(key,None)
    item["image"]=image
    return image


def validate_image(item):
    image=normalize_image(item)
    if not image:
        return
    if not str(image.get("url") or "").startswith("https://"):
        raise ValueError("imagen externa sin URL HTTPS")
    if not str(image.get("source_url") or "").startswith("https://"):
        raise ValueError("imagen externa sin página de origen HTTPS")


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
        headers={"User-Agent":"Mozilla/5.0 (compatible; TTiTTularesImage/2.0)","Accept":"image/*"}
        if referer: headers["Referer"]=referer
        req=urllib.request.Request(url,headers=headers)
        with urllib.request.urlopen(req,timeout=10) as r:
            if not str(r.geturl()).startswith("https://"): return False
            if not str(r.headers.get("content-type") or "").lower().startswith("image/"): return False
            data=r.read(12*1024*1024+1)
        if len(data)<4096 or len(data)>12*1024*1024: return False
        from PIL import Image, UnidentifiedImageError
        try:
            with Image.open(io.BytesIO(data)) as probe: probe.verify()
            with Image.open(io.BytesIO(data)) as image:
                image.load(); w,h=image.size
                return w>=320 and h>=180
        except (UnidentifiedImageError,OSError,SyntaxError):
            return False
    except Exception:
        return False


def _fetch_meta_image(page_url):
    try:
        req=urllib.request.Request(page_url,headers={"User-Agent":"Mozilla/5.0 (compatible; TTiTTularesImage/2.0)","Accept":"text/html,application/xhtml+xml"})
        with urllib.request.urlopen(req,timeout=10) as r:
            ctype=str(r.headers.get("content-type") or "").lower()
            if "html" not in ctype:return None
            final=r.geturl(); raw=r.read(1500000)
        parser=_MetaImageParser(); parser.feed(raw.decode("utf-8","ignore"))
        seen=set()
        for value in parser.images:
            url=urllib.parse.urljoin(final,value)
            if not url.startswith("https://") or url in seen:continue
            seen.add(url)
            if _valid_external_image(url,final):
                return url
    except Exception:
        return None
    return None


def _recover_image(item,row,events):
    image=normalize_image(item)
    if str(image.get("url") or "").strip():
        if _valid_external_image(str(image["url"]),str(image.get("source_url") or "")):
            item["image_search_status"]="found"; return True
        item.pop("image",None)
    pages=[]; seen=set()
    def add(url,source=""):
        url=str(url or "").strip()
        if not url.startswith("https://") or url in seen:return
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

def _finish_archive_image(item,row,events):
    for key in ("image_generation_attempts","image_persistence_attempts","image_semantic_rejections",
                "image_worker_id","image_worker_status","image_worker_dispatched_at",
                "image_telegram_delivered","image_telegram_delivered_at","image_telegram_message_id",
                "image_telegram_headline_message_id","image_telegram_sha256"):
        item.pop(key,None)
    item["image_strategy"]="existing_web_image"
    found=_recover_image(item,row,events)
    item["image_pending"]=False
    item["image_app_available"]=bool(found)
    if found:
        item["image_status"]="ready";item["image_delivery"]="app"
        item.pop("image_failure_reason",None)
    else:
        item.pop("image",None)
        item["image_status"]="none";item["image_delivery"]="none"
        item["image_failure_reason"]="No se encontró una imagen HTTPS verificable en las páginas de las fuentes del acontecimiento."
    return found


def _enrich_prepared_images(p,q,events):
    """Cierra búsquedas pendientes sin volver a introducir trabajo en ChatGPT Work."""
    changed=False
    rows={(str(x.get("event_id") or ""),int(x.get("revision") or 1)):x for x in q.get("items",[]) or []}
    for item in p.get("items",[]) or []:
        state=str(item.get("image_status") or "")
        if state in {"ready","none"}:
            continue
        eid=str(item.get("event_id") or "");revision=int(item.get("revision") or 1)
        before=json.dumps(item,ensure_ascii=False,sort_keys=True)
        _finish_archive_image(item,rows.get((eid,revision),{}),events)
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
            "with_image":True,"image_mode":"existing_web_image",
            "image_instruction":"Recupera una imagen real del mismo acontecimiento desde una fuente oficial/primaria o un medio fiable. No generes imágenes.",
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
                normalize_image(incoming)
                state=str(incoming.get("image_status") or "")
                if state not in {"ready","none"}: raise ValueError("image-only requiere imagen de archivo con URL o Sin imagen con razón; pending no resuelve el intento")
                patch_keys={"image","image_status","image_delivery","image_app_available","image_pending","image_failure_reason","image_none_reason","image_strategy","image_search_status","image_search_attempted_at"}
                item={**previous,**{k:v for k,v in incoming.items() if k in patch_keys}}
                if state=="none" and not item.get("image_failure_reason") and item.get("image_none_reason"):
                    item["image_failure_reason"]=item.get("image_none_reason")
                item.pop("image_none_reason",None)
                item["image_pending"]=state in {"pending","working"}
                item["image_delivery"]={"ready":"app","none":"none"}[state]
                item["image_app_available"]=state=="ready"
                if state=="ready" and not (item.get("image") or {}).get("url"): raise ValueError("imagen lista sin URL")
                if state=="none" and not item.get("image_failure_reason"): raise ValueError("sin imagen requiere razón")
                if state=="none":
                    item.pop("image",None) # Nunca mostrar una URL no accesible como imagen lista.
                if state=="none" and (str(previous.get("image_status") or "")!="none" or str(previous.get("image_failure_reason") or "")!=str(item.get("image_failure_reason") or "")):
                    ledger=load(ERRORS,{"items":[]})
                    record_error(ledger.setdefault("items",[]),eid,"imagen",item["image_failure_reason"],now)
                    ledger["items"]=ledger["items"][-200:];save(ERRORS,ledger)
                payload["prepared_item"]=item
            if st=="ready":
                item=validate_ready(payload)
                item["image_strategy"]="existing_web_image"
                if bool(row.get("with_image",True)):
                    if image_retry:
                        state=str(item.get("image_status") or "")
                        if state=="ready":
                            validate_image(item)
                            item["image_pending"]=False;item["image_delivery"]="app";item["image_app_available"]=True
                        elif state=="none":
                            item.pop("image",None);item["image_pending"]=False;item["image_delivery"]="none";item["image_app_available"]=False
                    else:
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
    compact={
        "prepared_item":{"event_id":"selftest","revision":1,"variants":{
            "Principal":"Titular de prueba",
            "A":"Remate compacto",
            "B":{"text":"Titular de prueba\n\nOtro remate"},
            "C":{"text":"🌶️ Remate ya marcado","remate":"🌶️ Remate ya marcado"},
        }}
    }
    normalized=validate_ready(compact)
    assert [v["label"] for v in normalized["variants"]]==["Principal","A","B","C"]
    assert all(v["text"].startswith("Titular de prueba\n\n🌶️ ") for v in normalized["variants"][1:])
    flat={"title":"Prueba","image":"https://cdn.example.test/photo.jpg","image_source":"Fuente","image_source_url":"https://example.test/story"}
    image=normalize_image(flat)
    assert image["url"]=="https://cdn.example.test/photo.jpg"
    assert image["source"]=="Fuente" and image["rights_status"]=="unverified"
    assert "image_url" not in flat and isinstance(flat["image"],dict)
    generated={"image":{"url":"https://example.test/generated.jpg","source":"TTiTTulares / ChatGPT","rights_status":"generated","generated":True}}
    try:
        normalize_image(generated)
    except ValueError:
        pass
    else:
        raise AssertionError("una imagen generada debe rechazarse")
    print("ARCHIVE_IMAGE_SELFTEST_OK")
    return 0

if "--selftest-images" in sys.argv:
    raise SystemExit(selftest_images())
if __name__=="__main__":
    raise SystemExit(main())
