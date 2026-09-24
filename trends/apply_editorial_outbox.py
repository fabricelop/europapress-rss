#!/usr/bin/env python3
from __future__ import annotations

import json
import unicodedata
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
TRENDS = ROOT / "trends"
OUTBOX = TRENDS / "editorial-outbox"
MADRID = ZoneInfo("Europe/Madrid")
ACTIVE = {"preparing", "update"}

def load(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default

def save(path: Path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def norm(value):
    text = unicodedata.normalize("NFD", str(value or ""))
    text = "".join(ch for ch in text if unicodedata.category(ch) != "Mn")
    return " ".join(text.casefold().split())

def validate_generated_image(item):
    image = item.get("image") or {}
    if not image.get("generated"):
        return
    url = str(image.get("url") or "").strip()
    prefix = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/"
    if not url.startswith(prefix) or not url.endswith(".svg"):
        raise ValueError("imagen generada sin URL raw SVG válida")
    if str(image.get("rights_status") or "") != "generated":
        raise ValueError("imagen generada sin rights_status=generated")
    if str(image.get("source") or "") != "TTendencias / ChatGPT":
        raise ValueError("imagen generada sin source esperado")
    filename = url[len(prefix):]
    if "/" in filename or ".." in filename:
        raise ValueError("ruta de imagen generada no válida")
    path = TRENDS / "generated-images" / filename
    if not path.exists():
        raise ValueError("fichero de imagen generada inexistente en main")
    svg = path.read_text(encoding="utf-8", errors="strict")
    low = svg.casefold()
    if "<svg" not in low or "</svg>" not in low:
        raise ValueError("SVG generado inválido")
    forbidden = ("<script", "<foreignobject", "javascript:", "http://", "https://", "data:")
    if any(token in low for token in forbidden):
        raise ValueError("SVG generado contiene recursos o código externo no permitido")
    if "viewbox=" not in low and not ("width=" in low and "height=" in low):
        raise ValueError("SVG generado sin dimensiones")

def validate_ready(payload):
    item = payload.get("prepared_item") or {}
    if not str(item.get("id") or "").strip():
        raise ValueError("prepared_item sin id")
    if not str((item.get("primary") or {}).get("text") or "").strip():
        raise ValueError("prepared_item sin primary.text")
    alts = item.get("alternatives") or []
    if len(alts) != 3:
        raise ValueError("prepared_item debe tener exactamente 3 alternativas")
    if any(not str(a.get("tweet_text") or "").strip() for a in alts):
        raise ValueError("alternativa sin tweet_text")
    texts = [item["primary"]["text"]] + [a["tweet_text"] for a in alts]
    if any(len(t) > 280 for t in texts):
        raise ValueError("tuit de más de 280 caracteres")
    validate_generated_image(item)
    return item

def sync_queue(requests_doc):
    items = []
    for req in requests_doc.get("requests", []) or []:
        if str(req.get("status") or "") not in ACTIVE:
            continue
        items.append({
            "id": req.get("id"),
            "name": req.get("name"),
            "rank": req.get("rank"),
            "status": req.get("status"),
            "requested_at": req.get("requested_at"),
            "revision": int(req.get("revision") or 0),
            "rewrite_instruction": req.get("rewrite_instruction") or req.get("rewrite_request") or "",
            "with_image": bool(req.get("with_image")),
            "image_mode": "existing_web_image",
            "image_instruction": "Busca una imagen existente REAL y pertinente del MISMO hecho actual. Método obligatorio y exhaustivo: 1) fuente oficial/primaria del hecho e inspección de og:image/twitter:image/imagen principal; 2) noticia ACTUAL de un medio fiable sobre el mismo hecho e inspección de su imagen principal/og:image; 3) búsqueda específica de imágenes usando protagonista/evento + contexto + fecha actual, abriendo el resultado y verificando que corresponda al hecho; 4) segunda búsqueda o segunda fuente fiable distinta. Prioriza imagen del hecho actual frente a archivo genérico. Comprueba que la URL sea HTTPS directa a una imagen y descarta logos, avatares irrelevantes, miniaturas engañosas e imágenes de eventos antiguos. Si una imagen es mediocre o dudosa, sigue buscando. No generes imágenes en este paso. Si encuentras una, guarda url, source, source_url, rights_status y alt. Solo declara not_found después de intentar las cuatro vías y explica brevemente los intentos. Si las cuatro vías fallan y generated_image_storage.enabled=true en editorial-config.json, crea un SVG editorial original no fotorrealista, guárdalo en trends/generated-images/<id>-r<revision>.svg y usa su URL raw como image.url con source="TTendencias / ChatGPT", rights_status="generated", generated=true. No inventes fotografías ni citas visuales.",
            "batch_id": req.get("batch_id"),
            "requested_together": req.get("requested_together") or [req.get("name")],
            "captured_with": req.get("captured_with") or [],
            "auto_queued": bool(req.get("auto_queued")),
            "anticipated": bool(req.get("anticipated")),
            "anticipated_at": req.get("anticipated_at"),
            "anticipated_best_rank": req.get("anticipated_best_rank"),
            "anticipated_social_source_count": int(req.get("anticipated_social_source_count") or 0),
            "anticipated_news_source_count": int(req.get("anticipated_news_source_count") or 0),
            "anticipated_news_title": req.get("anticipated_news_title") or "",
            "anticipated_entered_top10_at": req.get("anticipated_entered_top10_at"),
        })
    items.sort(key=lambda x: str(x.get("requested_at") or ""))
    save(TRENDS / "editorial-queue.json", {
        "project": "TTendencias",
        "updated_at": datetime.now(MADRID).isoformat(timespec="seconds"),
        "count": len(items),
        "items": items,
    })
    return items

def main():
    requests_path = TRENDS / "requests.json"
    prepared_path = TRENDS / "prepared.json"
    runtime_path = TRENDS / "editorial-runtime.json"

    requests_doc = load(requests_path, {"requests": []})
    prepared_doc = load(prepared_path, {"project": "TTendencias", "items": []})
    runtime = load(runtime_path, {"project": "TTendencias"})
    processed = []
    errors = []

    files = sorted(OUTBOX.glob("*.json")) if OUTBOX.exists() else []
    if not files:
        sync_queue(requests_doc)
        print("Sin resultados editoriales pendientes de aplicar.")
        return 0

    now = datetime.now(MADRID).isoformat(timespec="seconds")
    runtime.update({
        "engine": "chatgpt-automation-outbox",
        "last_started_at": now,
        "status": "running",
        "error": None,
        "updated_at": now,
    })
    save(runtime_path, runtime)

    for path in files:
        try:
            payload = load(path, None)
            if not isinstance(payload, dict):
                raise ValueError("JSON de outbox inválido")

            req_id = str(payload.get("id") or "")
            revision = int(payload.get("revision") or 0)
            req = next((r for r in requests_doc.get("requests", []) if str(r.get("id") or "") == req_id), None)
            if req is None:
                print(f"Ignorado {path.name}: request inexistente")
                path.unlink()
                continue

            if int(req.get("revision") or 0) != revision:
                print(f"Ignorado {path.name}: revisión obsoleta")
                path.unlink()
                continue

            if str(req.get("status") or "") not in ACTIVE:
                print(f"Ignorado {path.name}: estado actual {req.get('status')}")
                path.unlink()
                continue

            result_status = str(payload.get("status") or "")
            if result_status == "ready":
                item = validate_ready(payload)
                item["id"] = req_id
                item["revision"] = revision
                item.setdefault("trend_name", req.get("name"))
                if bool(req.get("with_image")):
                    image = item.get("image") or {}
                    if str(image.get("url") or "").strip():
                        item["image_search_status"] = item.get("image_search_status") or "found"
                    else:
                        item["image_search_status"] = "not_found"
                        item["image_note"] = item.get("image_note") or "Sin imagen adecuada encontrada tras la búsqueda editorial."
                related = item.get("related_trends") or [req.get("name")]
                related_norm = {norm(x) for x in related if x}

                # Evitar solapes ambiguos: una tendencia no puede estar en dos tarjetas.
                kept = []
                for existing in prepared_doc.setdefault("items", []):
                    existing_rel = existing.get("related_trends") or [existing.get("trend_name")]
                    if str(existing.get("id") or "") == req_id:
                        continue
                    if related_norm.intersection({norm(x) for x in existing_rel if x}):
                        continue
                    kept.append(existing)
                kept.append(item)
                prepared_doc["items"] = kept
                prepared_doc["updated_at"] = item.get("generated_at") or now

                # Marcar como ready todos los requests activos representados
                # inequívocamente por related_trends y con la misma revisión.
                target_requests = []
                for candidate in requests_doc.get("requests", []) or []:
                    if str(candidate.get("status") or "") not in ACTIVE:
                        continue
                    if int(candidate.get("revision") or 0) != revision:
                        continue
                    if str(candidate.get("id") or "") == req_id or norm(candidate.get("name")) in related_norm:
                        target_requests.append(candidate)

                if not target_requests:
                    target_requests = [req]

                for target in target_requests:
                    target["status"] = "ready"
                    target["ready_at"] = item.get("generated_at") or now
                    target["delivery_confirmation"] = "prepared_web"
                    target["editorial_engine"] = "chatgpt-automation-outbox"
                    target.pop("problem_reason", None)
                    target.pop("problematic_at", None)
                    if str(target.get("id") or "") not in processed:
                        processed.append(str(target.get("id") or ""))

            elif result_status == "problematic":
                reason = str(payload.get("problem_reason") or "").strip()
                if not reason:
                    raise ValueError("problematic sin problem_reason")
                req["status"] = "problematic"
                req["problematic_at"] = now
                req["problem_reason"] = reason
                req["editorial_engine"] = "chatgpt-automation-outbox"
                req.pop("ready_at", None)
                req.pop("delivery_confirmation", None)
            else:
                raise ValueError(f"status editorial no válido: {result_status}")

            if req_id not in processed:
                processed.append(req_id)
            path.unlink()
        except Exception as exc:
            errors.append(f"{path.name}: {type(exc).__name__}: {exc}")
            print("ERROR", errors[-1])

    requests_doc["updated_at"] = datetime.now(MADRID).isoformat(timespec="seconds")
    save(requests_path, requests_doc)
    save(prepared_path, prepared_doc)
    remaining = sync_queue(requests_doc)

    done = datetime.now(MADRID).isoformat(timespec="seconds")
    runtime.update({
        "last_completed_at": done if not errors else runtime.get("last_completed_at"),
        "processed_ids": processed,
        "remaining_ids": [x.get("id") for x in remaining],
        "status": "success" if not errors else "failure",
        "error": "; ".join(errors)[:2000] if errors else None,
        "api_failover_enabled": False,
        "updated_at": done,
    })
    save(runtime_path, runtime)

    print(json.dumps({
        "processed": processed,
        "remaining": [x.get("id") for x in remaining],
        "errors": errors,
    }, ensure_ascii=False))
    return 0 if not errors else 1

if __name__ == "__main__":
    raise SystemExit(main())
