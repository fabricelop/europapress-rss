#!/usr/bin/env python3
from __future__ import annotations

import json
import hashlib
import re
import unicodedata
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
TRENDS = ROOT / "trends"
OUTBOX = TRENDS / "editorial-outbox"
MADRID = ZoneInfo("Europe/Madrid")
ACTIVE = {"preparing", "update", "problematic"}
APPLYABLE = ACTIVE | {"ready"}

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


def validate_generated_image(item, expected_id=None, expected_revision=None):
    import base64
    image = item.get("image") or {}
    if not image.get("generated"):
        raise ValueError("imagen final debe ser generated=true")
    url = str(image.get("url") or "").strip()
    if str(image.get("rights_status") or "") != "generated":
        raise ValueError("imagen generada sin rights_status=generated")
    source = str(image.get("source") or "")
    if source != "TTendencias / ChatGPT ImageGen":
        raise ValueError("ai_image debe proceder de ChatGPT ImageGen")
    if str(image.get("provider") or "") != "chat-imagegen":
        raise ValueError("ai_image con provider no admitido")
    if str(image.get("origin") or "") != "executing_chat":
        raise ValueError("ai_image no generado en el chat ejecutor")
    guard = image.get("context_guard") or {}
    guard_version = int(guard.get("version") or 0)
    if guard_version != 3:
        raise ValueError("ai_image requiere context_guard V3")
    if str(guard.get("scope") or "") != "current_item_only":
        raise ValueError("imagen generada sin scope current_item_only")
    if expected_id is not None and str(guard.get("trend_id") or "") != str(expected_id):
        raise ValueError("context_guard pertenece a otra tendencia")
    if expected_revision is not None and int(guard.get("revision") if guard.get("revision") is not None else -1) != int(expected_revision):
        raise ValueError("context_guard pertenece a otra revisión")
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

    # Normalization belongs to Actions; the producer need not have Pillow or
    # a bridge between its filesystem and the connector's JS runtime.
    if len(data) > 12_000_000:
        raise ValueError("imagen inline supera el límite de entrada de 12 MB")
    _validate_raster_integrity(data, "imagen raster inline")
    import io
    from PIL import Image, ImageOps
    with Image.open(io.BytesIO(data)) as original:
        normalized = ImageOps.exif_transpose(original).convert("RGB")
        # Preserve the validator's minimum width for portrait images too.
        width, height = normalized.size
        scale = min(1.0, max(512 / max(width, height), 480 / width, 270 / height))
        if scale < 1:
            normalized = normalized.resize((round(width * scale), round(height * scale)), Image.Resampling.LANCZOS)
        for quality in (82, 72, 60, 45):
            output = io.BytesIO()
            normalized.save(output, format="JPEG", quality=quality, optimize=True)
            data = output.getvalue()
            if len(data) <= 350_000:
                break
        if len(data) > 350_000:
            raise ValueError("imagen normalizada supera 350 KB")
    _validate_raster_integrity(data, "imagen normalizada")
    ext = ".jpg"

    generated_dir = TRENDS / "generated-images"
    generated_dir.mkdir(parents=True, exist_ok=True)
    attempt = int(image.get("generation_attempt") or 1)
    filename = f"{req_id}-r{revision}-ai{attempt}{ext}"
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
    image["sha256"] = hashlib.sha256(data).hexdigest()
    item["image"] = image
    return True


def checkpoint_image(payload, req_id, revision):
    """Persist an accepted image before validating any editorial text."""
    item = payload.get("prepared_item") or {}
    image = item.get("image") or payload.get("image")
    cache_path = TRENDS / "image-cache" / f"{req_id}-r{revision}.json"
    if not image or not image.get("url"):
        cached = load(cache_path, {})
        if cached.get("id") == req_id and cached.get("revision") == revision:
            image = cached.get("image")
    if not image:
        raise ValueError("sin imagen ni checkpoint reutilizable para id/revision")
    holder = {"image": dict(image)}
    # Validate metadata as well as pixels before writing a durable cache.
    validate_generated_image(holder, req_id, revision)
    materialize_inline_generated_image(holder, req_id, revision)
    validate_generated_image(holder, req_id, revision)
    image = holder["image"]
    expected_prefix = f"{req_id}-r{revision}-ai"
    if not Path(image["url"]).stem.startswith(expected_prefix):
        raise ValueError("imagen de otro id/revision; no se puede reutilizar")
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    save(cache_path, {"id": req_id, "revision": revision, "image": image})
    item["image"] = image
    payload["prepared_item"] = item
    return image


def checkpoint_ai_image(payload, req_id, revision):
    """Rechaza IA inline: la imagen solo puede llegar por image-outbox V3."""
    item = payload.get("prepared_item") or {}
    ai = item.get("ai_image")
    selected = item.get("image") or {}
    if not ai and not (isinstance(selected, dict) and selected.get("generated") is True):
        return None
    item.pop("ai_image", None)
    item["ai_image_status"] = "pending"
    item["ai_image_inline_rejected"] = True
    item["ai_image_failure_reason"] = "La IA inline se descartó; debe llegar por trends/image-outbox V3."
    if str(item.get("image_choice") or "") == "ai" or (isinstance(selected, dict) and selected.get("generated") is True):
        item.pop("image", None)
        item["image_choice"] = "none"
        item["image_status"] = "none"
    payload["prepared_item"] = item
    return None


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
    # La imagen es paralela y nunca bloquea la validez editorial del READY.
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
    top30_names = {norm(x.get("name")) for x in (recent.get("items") or recent.get("top10") or []) if 1 <= int(x.get("rank") or 0) <= 30 and x.get("name")}
    items = []
    for req in requests_doc.get("requests", []) or []:
        status = str(req.get("status") or "")
        if status not in ACTIVE:
            continue
        if status == "problematic" and norm(req.get("name")) not in top30_names:
            continue
        items.append({
            "red_review_request": req.get("red_review_request"),
            "review_source": req.get("review_source"),
            "review_error": req.get("review_error"),
            "automatic_grouping": req.get("automatic_grouping"),
            "published_context": req.get("published_context"),
            "task": req.get("task"),
            "anticipation_request": req.get("anticipation_request"),
            "anticipated_name": req.get("anticipated_name"),
            "anticipation_signal": req.get("anticipation_signal"),
            "anticipation_origin_id": req.get("anticipation_origin_id"),
            "anticipation_draft": req.get("anticipation_draft"),
            "listas_grouping_request": req.get("listas_grouping_request"),
            "grouping_candidates": req.get("grouping_candidates"),
            "grouping_state": req.get("grouping_state"),
            "grouping_error": req.get("grouping_error"),
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
    # Evita starvation: trabajo nuevo/revisiones primero; problematic al final.
    items.sort(key=lambda x: (
        1 if str(x.get("status") or "") == "problematic" else 0,
        2 if x.get("red_review_request") else 1 if x.get("anticipation_request") else 0,
        str(x.get("requested_at") or ""),
    ))
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
    manual_path = TRENDS / "telegram-manual-explained.json"
    runtime_path = TRENDS / "editorial-runtime.json"

    requests_doc = load(requests_path, {"requests": []})
    prepared_doc = load(prepared_path, {"project": "TTendencias", "items": []})
    manual_doc = load(manual_path, {"project": "TTendencias", "items": []})
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
            if not re.fullmatch(r"[A-Za-z0-9_-]+", req_id) or revision < 0:
                raise ValueError("id/revision no válido")
            req = next((r for r in requests_doc.get("requests", []) if str(r.get("id") or "") == req_id), None)
            if req is None:
                print(f"Ignorado {path.name}: request inexistente")
                path.unlink()
                continue

            if int(req.get("revision") or 0) != revision:
                print(f"Ignorado {path.name}: revisión obsoleta")
                path.unlink()
                continue

            if str(req.get("status") or "") not in APPLYABLE:
                print(f"Ignorado {path.name}: estado actual {req.get('status')}")
                path.unlink()
                continue

            if req.get("anticipation_request"):
                raise ValueError("Los borradores Radar solo se aplican por anticipation-outbox; no son Listas")

            result_status = str(payload.get("status") or "")
            if result_status == "ready":
                # El texto se cierra aunque un productor antiguo intente incluir
                # IA inline; el raster solo se admite por image-outbox V3.
                checkpoint_ai_image(payload, req_id, revision)
                save(path, payload)
                item = validate_ready(payload)
                item["id"] = req_id
                item["revision"] = revision
                item.setdefault("trend_name", req.get("name"))
                # No existe requisito de imagen para cerrar el item.
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

                # El contrato vigente cierra TEXTO como explained en ambos
                # registros. No copiar una explicación a otros términos por
                # related_trends: las agrupaciones se resuelven después.
                explained_at = str(item.get("generated_at") or now)
                explanation = str(item.get("explanation") or (item.get("primary") or {}).get("text") or "").strip()
                closer_text = str(item.get("closer_text") or "").strip()
                raw_sources = item.get("verification_sources") or item.get("sources") or []
                verification_sources = []
                for source in raw_sources:
                    if isinstance(source, dict):
                        url = str(source.get("url") or "").strip()
                    else:
                        url = str(source or "").strip()
                    if url:
                        verification_sources.append({"url": url})

                manual_item = {
                    "id": req_id,
                    "name": str(item.get("trend_name") or req.get("name") or ""),
                    "revision": revision,
                    "status": "explained",
                    "explained_at": explained_at,
                    "updated_at": explained_at,
                    "explanation": explanation,
                    "closer_text": closer_text,
                    "rank": int(item.get("rank") or req.get("rank") or 0),
                    "rank_at_explanation": int(item.get("rank") or req.get("rank") or 0),
                    "category": str(item.get("category") or req.get("category") or "Actualidad"),
                    "source": "editorial_outbox_applied",
                    "editorial_engine": "chatgpt-automation-outbox",
                    "verification_sources": verification_sources,
                    "news_note": str(item.get("news_note") or ""),
                    "group_id": str(item.get("group_id") or f"grp-{req_id}"),
                    "explanation_group_id": str(item.get("explanation_group_id") or item.get("group_id") or f"grp-{req_id}"),
                    "group_title": str(item.get("group_title") or item.get("trend_name") or req.get("name") or ""),
                    "group_leader_id": str(item.get("group_leader_id") or req_id),
                    "trend_names": item.get("trend_names") or [str(item.get("trend_name") or req.get("name") or "")],
                    "grouped_member_revisions": item.get("grouped_member_revisions") or [{"id": req_id, "revision": revision}],
                    "with_image": bool(req.get("with_image") or item.get("with_image")),
                    "image_strategy": str(item.get("image_strategy") or "ai_plus_fallback"),
                    "ai_image_status": "pending" if bool(req.get("with_image") or item.get("with_image")) else "none",
                    "fallback_image_status": "pending" if bool(req.get("with_image") or item.get("with_image")) else "none",
                    "image_status": "pending" if bool(req.get("with_image") or item.get("with_image")) else "none",
                    "image_choice": "none",
                    "image_pending": bool(req.get("with_image") or item.get("with_image")),
                    "editorial_grouping_state": "pending",
                    "telegram_package_status": "pending",
                }

                manual_items = [
                    existing for existing in (manual_doc.get("items") or [])
                    if not (
                        str(existing.get("id") or "") == req_id
                        and int(existing.get("revision") or 0) == revision
                    )
                ]
                manual_items.append(manual_item)
                manual_doc["items"] = manual_items
                manual_doc["updated_at"] = explained_at
                manual_doc["count"] = len(manual_items)

                req.update({
                    "status": "explained",
                    "updated_at": explained_at,
                    "explained_at": explained_at,
                    "last_attempt_at": explained_at,
                    "explanation": explanation,
                    "closer_text": closer_text,
                    "rank_at_explanation": manual_item["rank_at_explanation"],
                    "category": manual_item["category"],
                    "source": manual_item["source"],
                    "editorial_engine": manual_item["editorial_engine"],
                    "verification_sources": verification_sources,
                    "news_note": manual_item["news_note"],
                    "group_id": manual_item["group_id"],
                    "explanation_group_id": manual_item["explanation_group_id"],
                    "group_title": manual_item["group_title"],
                    "group_leader_id": manual_item["group_leader_id"],
                    "trend_names": manual_item["trend_names"],
                    "grouped_member_revisions": manual_item["grouped_member_revisions"],
                    "editorial_grouping_state": "pending",
                    "image_strategy": manual_item["image_strategy"],
                    "fallback_image_status": manual_item["fallback_image_status"],
                    "ai_image_status": manual_item["ai_image_status"],
                    "image_status": manual_item["image_status"],
                    "image_choice": "none",
                    "image_pending": manual_item["image_pending"],
                    "telegram_package_status": "pending",
                })
                req.pop("ready_at", None)
                req.pop("delivery_confirmation", None)
                req.pop("problem_reason", None)
                req.pop("problematic_at", None)
                req.pop("problematic_attempts", None)
                if req_id not in processed:
                    processed.append(req_id)

            elif result_status == "image_checkpoint":
                image = checkpoint_image(payload, req_id, revision)
                req["image_checkpoint"] = {
                    "revision": revision,
                    "url": image["url"],
                    "cache_path": f"trends/image-cache/{req_id}-r{revision}.json",
                    "saved_at": now,
                }
                # Keep the request pending; a saved image is not a ready tweet.
                path.unlink()
                continue

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
    save(manual_path, manual_doc)
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
