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
ACTIVE = {"preparing", "update", "problematic"}

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

def _validate_raster_integrity(data: bytes, label: str):
    import io
    from PIL import Image, ImageStat, UnidentifiedImageError

    if len(data) < 4096:
        raise ValueError(f"{label}: imagen raster demasiado pequeña o inválida")
    try:
        with Image.open(io.BytesIO(data)) as probe:
            probe.verify()
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            width, height = image.size
            if width < 480 or height < 270:
                raise ValueError(f"{label}: dimensiones insuficientes ({width}x{height})")

            # Rechaza transparencia masiva, típica de un render incompleto.
            if "A" in image.getbands():
                alpha = image.getchannel("A").resize((128, 128))
                alpha_values = list(alpha.getdata())
                transparent_ratio = sum(1 for v in alpha_values if v < 16) / max(1, len(alpha_values))
                if transparent_ratio > 0.25:
                    raise ValueError(f"{label}: demasiada superficie transparente ({transparent_ratio:.0%})")

            rgb = image.convert("RGB")
            rgb.thumbnail((256, 256))
            width2, height2 = rgb.size
            pixels = list(rgb.getdata())
            if not pixels:
                raise ValueError(f"{label}: raster vacío")

            near_black = lambda p: p[0] < 12 and p[1] < 12 and p[2] < 12
            black_ratio = sum(1 for p in pixels if near_black(p)) / len(pixels)
            if black_ratio > 0.60:
                raise ValueError(f"{label}: imagen anómalamente negra ({black_ratio:.0%})")

            # Detecta el fallo observado: una franja válida arriba y el resto negro.
            bottom_start = int(height2 * 0.45)
            bottom = [rgb.getpixel((x, y)) for y in range(bottom_start, height2) for x in range(width2)]
            if bottom:
                bottom_black = sum(1 for p in bottom if near_black(p)) / len(bottom)
                if bottom_black > 0.88:
                    raise ValueError(f"{label}: bloque negro/incompleto en la parte inferior ({bottom_black:.0%})")

            # Rechaza un raster prácticamente plano/vacío.
            gray = rgb.convert("L")
            stat = ImageStat.Stat(gray)
            if stat.stddev and stat.stddev[0] < 4.0:
                raise ValueError(f"{label}: imagen prácticamente uniforme o vacía")
    except (UnidentifiedImageError, OSError, SyntaxError) as exc:
        raise ValueError(f"{label}: raster corrupto o truncado: {exc}")


def validate_generated_image(item):
    import base64
    image = item.get("image") or {}
    if not image.get("generated"):
        raise ValueError("imagen final debe ser generated=true")
    url = str(image.get("url") or "").strip()
    if str(image.get("rights_status") or "") != "generated":
        raise ValueError("imagen generada sin rights_status=generated")
    if str(image.get("source") or "") != "TTendencias / ChatGPT":
        raise ValueError("imagen generada sin source esperado")
    style = str(image.get("style_version") or "")
    check = image.get("style_check") or {}
    required_checks = [
        "reviewed_after_generation",
        "single_narrative_scene",
        "visual_gag_without_text",
        "no_infographic_layout",
        "no_diagram_arrows_or_connectors",
        "no_ui_or_scoreboard_layout",
        "low_text",
        "depth_lighting_texture",
    ]
    if style != "editorial-scene-v2-cleveland" or not all(check.get(k) is True for k in required_checks):
        raise ValueError("imagen generada sin control visual editorial-scene-v2-cleveland completo")
    prefix = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/"
    if url.startswith("data:image/"):
        try:
            header, payload = url.split(",", 1)
            if ";base64" not in header:
                raise ValueError("data URL no base64")
            mime = header[5:].split(";",1)[0].casefold()
            if mime not in {"image/png","image/webp","image/jpeg"}:
                raise ValueError("mime raster no permitido")
            data = base64.b64decode(payload, validate=True)
        except Exception as exc:
            raise ValueError(f"data URL raster inválida: {exc}")
        _validate_raster_integrity(data, "imagen raster inline")
        return
    if not url.startswith(prefix):
        raise ValueError("imagen generada sin URL raw válida")
    filename = url[len(prefix):]
    if "/" in filename or ".." in filename:
        raise ValueError("ruta de imagen generada no válida")
    ext = Path(filename).suffix.casefold()
    if ext not in {".png", ".webp", ".jpg", ".jpeg"}:
        raise ValueError("imagen final debe ser raster PNG/WebP/JPEG; SVG no permitido")
    path = TRENDS / "generated-images" / filename
    if not path.exists():
        raise ValueError("fichero de imagen generada inexistente en main")
    data = path.read_bytes()
    _validate_raster_integrity(data, f"imagen generada {filename}")

def materialize_inline_generated_image(item, req_id: str, revision: int):
    """Convert the automation's text-safe data URL handoff into a real raster file.

    The scheduled ChatGPT task only needs to persist one UTF-8 outbox. GitHub
    Actions owns the binary write, which avoids connector restrictions on
    binary Git object operations during scheduled executions.
    """
    import base64

    image = item.get("image") or {}
    url = str(image.get("url") or "").strip()
    if not url.startswith("data:image/"):
        return False

    try:
        header, payload = url.split(",", 1)
        if ";base64" not in header:
            raise ValueError("data URL no base64")
        mime = header[5:].split(";", 1)[0].casefold()
        ext_by_mime = {
            "image/jpeg": ".jpg",
            "image/png": ".png",
            "image/webp": ".webp",
        }
        ext = ext_by_mime.get(mime)
        if not ext:
            raise ValueError(f"mime raster no permitido: {mime}")
        data = base64.b64decode(payload, validate=True)
    except Exception as exc:
        raise ValueError(f"data URL raster inválida: {exc}")

    # Keep the text outbox small enough to be reliable through the connector.
    if len(data) > 350_000:
        raise ValueError(
            f"imagen inline demasiado grande ({len(data)} bytes); "
            "redimensiona/comprime a ~512 px y JPEG/WebP eficiente"
        )

    _validate_raster_integrity(data, "imagen raster inline")

    generated_dir = TRENDS / "generated-images"
    generated_dir.mkdir(parents=True, exist_ok=True)
    filename = f"{req_id}-r{revision}{ext}"
    path = generated_dir / filename
    path.write_bytes(data)

    image["url"] = (
        "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
        f"trends/generated-images/{filename}"
    )
    image["source_url"] = (
        "https://github.com/fabricelop/europapress-rss/blob/main/"
        f"trends/generated-images/{filename}"
    )
    image["handoff"] = "inline-outbox-materialized-by-actions"
    item["image"] = image
    return True


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

def image_queue_policy():
    policy = (load(TRENDS / "editorial-config.json", {}) or {}).get("editorial", {}).get("image_policy", {})
    return (
        str(policy.get("mode") or "generated_editorial_image"),
        str(policy.get("queue_instruction") or "Genera SIEMPRE una imagen editorial ORIGINAL para la tendencia; no uses imágenes encontradas en Internet como imagen final."),
    )

def sync_queue(requests_doc):
    image_mode, image_instruction = image_queue_policy()
    recent = load(TRENDS / "recent.json", {})
    top10_names = {norm(x.get("name")) for x in (recent.get("items") or recent.get("top10") or []) if int(x.get("rank") or 0) <= 10 and x.get("name")}
    items = []
    for req in requests_doc.get("requests", []) or []:
        status = str(req.get("status") or "")
        if status not in ACTIVE:
            continue
        if status == "problematic" and norm(req.get("name")) not in top10_names:
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
            "image_mode": image_mode,
            "image_instruction": image_instruction,
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
                raw_item = payload.get("prepared_item") or {}
                materialize_inline_generated_image(raw_item, req_id, revision)
                item = validate_ready(payload)
                item["id"] = req_id
                item["revision"] = revision
                item.setdefault("trend_name", req.get("name"))
                if bool(req.get("with_image")):
                    image = item.get("image") or {}
                    if not image.get("generated") or not str(image.get("url") or "").strip():
                        raise ValueError("item ready sin imagen raster generada obligatoria")
                    item.pop("image_search_status", None)
                    item.pop("image_note", None)
                    item.pop("image_generation_status", None)
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
                    if int(target.get("problematic_attempts") or 0):
                        item.setdefault("problematic_attempts_before_ready", int(target.get("problematic_attempts") or 0))
                    target.pop("problem_reason", None)
                    target.pop("problematic_at", None)
                    target.pop("problematic_attempts", None)
                    if str(target.get("id") or "") not in processed:
                        processed.append(str(target.get("id") or ""))

            elif result_status == "problematic":
                reason = str(payload.get("problem_reason") or "").strip()
                if not reason:
                    raise ValueError("problematic sin problem_reason")
                req["status"] = "problematic"
                req["problematic_at"] = now
                req["problem_reason"] = reason
                req["problematic_attempts"] = int(req.get("problematic_attempts") or 0) + 1
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
    remaining_active = [
        x for x in remaining
        if str(x.get("status") or "") in {"preparing", "update"}
    ]
    remaining_problematic = [
        x for x in remaining
        if str(x.get("status") or "") == "problematic"
    ]
    queue_complete = not remaining_active
    runtime_status = "failure" if errors else ("success" if queue_complete else "waiting")
    runtime.update({
        "last_completed_at": done if (not errors and queue_complete) else runtime.get("last_completed_at"),
        "processed_ids": processed,
        "remaining_ids": [x.get("id") for x in remaining],
        "remaining_active_ids": [x.get("id") for x in remaining_active],
        "remaining_problematic_ids": [x.get("id") for x in remaining_problematic],
        "queue_complete": queue_complete,
        "status": runtime_status,
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
