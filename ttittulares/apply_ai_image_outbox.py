#!/usr/bin/env python3
"""Materializa un único intento IA y lo adjunta a una noticia READY.

Este consumidor es deliberadamente independiente del outbox editorial:
un fallo de imagen nunca cambia el texto, el tuit ni el estado READY.
"""
from __future__ import annotations
import json
import sys
import os
import base64
import hashlib
from urllib.request import Request, urlopen
from datetime import datetime, timezone
from pathlib import Path

from apply_editorial_outbox import TT, PREP, DECISIONS, load, save, _materialize_ai_image, _select_image

OUTBOX = TT / "image-outbox"


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def selftest():
    import base64, io
    from PIL import Image
    im=Image.new("RGB",(640,360))
    px=im.load()
    for y in range(360):
        for x in range(640):
            px[x,y]=((x*3+y)%256,(y*5+x//2)%256,(x+y*2)%256)
    raw=io.BytesIO();im.save(raw,format="JPEG",quality=88)
    data=base64.b64encode(raw.getvalue()).decode("ascii")
    item={
        "event_id":"selftest-ai","revision":1,"title":"Selftest",
        "ai_image_attempt":1,
        "ai_image":{
            "url":"data:image/jpeg;base64,"+data,
            "source":"TTiTTulares / ChatGPT ImageGen","rights_status":"generated","generated":True,
            "provider":"chat-imagegen","origin":"executing_chat",
            "generation_attempt":1,
            "context_guard":{"version":3,"event_id":"selftest-ai","revision":1,"scope":"current_item_only"},
        },
    }
    assert _materialize_ai_image(item)
    url=item["ai_image"]["url"]
    assert url.endswith("/ttittulares/generated-images/selftest-ai-r1-ai1.jpg")
    path=TT/"generated-images"/"selftest-ai-r1-ai1.jpg"
    assert path.is_file() and path.stat().st_size>4096
    path.unlink()
    rejected={**item,"ai_image":dict(item["ai_image"],provider="chat-svg")}
    try:
        _materialize_ai_image(rejected)
    except ValueError as exc:
        assert "provider" in str(exc)
    else:
        raise AssertionError("chat-svg no puede aceptarse como ai_image")
    print("TTITTULARES_AI_IMAGE_SELFTEST_OK")
    return 0



def _hydrate_comment_chunked_ai(payload):
    ai = payload.get("ai_image")
    if not isinstance(ai, dict):
        return False
    refs = ai.pop("comment_chunks", None)
    if not refs:
        return False
    if not isinstance(refs, list) or not refs or len(refs) > 64:
        raise ValueError("comment_chunks IA inválido")
    repo = os.environ.get("GITHUB_REPOSITORY", "").strip()
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not repo or not token:
        raise ValueError("faltan credenciales GitHub para recuperar chunks IA")
    eid = str(payload.get("event_id") or "")
    rev = int(payload.get("revision") or 1)
    attempt = max(1, int(payload.get("attempt") or 1))
    parts = []
    for idx, cid in enumerate(refs):
        url = f"https://api.github.com/repos/{repo}/issues/comments/{int(cid)}"
        req = Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "ttittulares-image-bot"})
        with urlopen(req, timeout=20) as resp:
            body = json.loads(resp.read().decode("utf-8")).get("body") or ""
        marker = f"TTITTULARES_IMAGE_CHUNK_V1 {eid} r{rev} ai{attempt} {idx+1}/{len(refs)}"
        if not body.startswith(marker + "\n"):
            raise ValueError("marker de chunk IA no coincide")
        parts.append(body.split("\n", 1)[1].strip())
    joined = "".join(parts)
    raw = base64.b64decode(joined, validate=True)
    expected = str(ai.pop("chunk_sha256", "") or "").lower()
    if expected and hashlib.sha256(raw).hexdigest().lower() != expected:
        raise ValueError("SHA-256 de imagen IA no coincide")
    mime = str(ai.pop("chunk_mime", "image/jpeg") or "image/jpeg").casefold()
    if mime not in {"image/jpeg", "image/png", "image/webp"}:
        raise ValueError("mime de chunks IA no permitido")
    ai["url"] = f"data:{mime};base64," + joined
    return True


def _hydrate_chunked_ai(payload):
    """Reconstruye un data URL desde partes de texto dentro de image-outbox.

    Permite transportar el mismo raster generado por ChatGPT sin incrustar decenas
    de KB de Base64 en un único JSON. No crea un nuevo intento de generación.
    """
    ai = payload.get("ai_image")
    if not isinstance(ai, dict):
        return []
    refs = ai.pop("chunk_files", None)
    if not refs:
        return []
    if not isinstance(refs, list) or not refs or len(refs) > 64:
        raise ValueError("chunk_files IA inválido")
    root = OUTBOX.resolve()
    files = []
    parts = []
    for ref in refs:
        rel = Path(str(ref or ""))
        if rel.is_absolute() or ".." in rel.parts:
            raise ValueError("ruta de chunk IA inválida")
        part = (OUTBOX / rel).resolve()
        if part.parent != root and root not in part.parents:
            raise ValueError("chunk IA fuera de image-outbox")
        if not part.is_file():
            raise ValueError("falta chunk IA: " + rel.as_posix())
        text = part.read_text(encoding="ascii").strip()
        if not text:
            raise ValueError("chunk IA vacío: " + rel.as_posix())
        files.append(part)
        parts.append(text)
    mime = str(ai.pop("chunk_mime", "image/jpeg") or "image/jpeg").casefold()
    if mime not in {"image/jpeg", "image/png", "image/webp"}:
        raise ValueError("mime de chunks IA no permitido")
    ai["url"] = f"data:{mime};base64," + "".join(parts)
    return files


def main():
    doc = load(PREP, {"project": "TTiTTulares", "items": []})
    decisions = load(DECISIONS, {"items": []})
    files = sorted(OUTBOX.glob("*.json")) if OUTBOX.exists() else []
    if not files:
        print("TTITTULARES_AI_IMAGE_OUTBOX_EMPTY")
        return 0

    changed = False
    processed = []
    waiting = []
    for path in files:
        payload = load(path, None)
        if not isinstance(payload, dict):
            path.unlink(missing_ok=True)
            changed = True
            continue
        eid = str(payload.get("event_id") or "").strip()
        revision = int(payload.get("revision") or 1)
        attempt = max(1, int(payload.get("attempt") or 1))
        item = next((x for x in doc.get("items", [])
                     if str(x.get("event_id") or "") == eid
                     and int(x.get("revision") or 1) == revision), None)
        if item is None:
            terminal = next((x for x in reversed(decisions.get("items", []))
                             if str(x.get("event_id") or "") == eid
                             and str(x.get("status") or "").lower() in {"published","dismissed"}), None)
            if terminal:
                path.unlink(missing_ok=True)
                processed.append(eid + ":cancelled")
                changed = True
                continue
            waiting.append(path.name)
            continue

        current_attempt = int(item.get("ai_image_attempt") or 0)
        expected_attempt = current_attempt or 1
        if attempt != expected_attempt:
            path.unlink(missing_ok=True)
            processed.append(eid + ":attempt-mismatch")
            changed = True
            continue

        status = str(payload.get("status") or "").lower()
        previous_ai = dict(item.get("ai_image") or {})
        chunk_files = []
        if status == "ready" and isinstance(payload.get("ai_image"), dict):
            try:
                if not _hydrate_comment_chunked_ai(payload):
                    chunk_files = _hydrate_chunked_ai(payload)
            except Exception as exc:
                status = "failed"
                payload["reason"] = str(exc)[:500]
        if status == "ready" and isinstance(payload.get("ai_image"), dict):
            holder = {
                "event_id": eid,
                "revision": revision,
                "title": item.get("title") or "",
                "ai_image": dict(payload["ai_image"]),
                "ai_image_attempt": attempt,
            }
            try:
                _materialize_ai_image(holder)
                new_sha = str((holder.get("ai_image") or {}).get("sha256") or "").lower()
                if new_sha:
                    collision = next((row for row in doc.get("items", [])
                                      if str(row.get("event_id") or "") != eid
                                      and str((row.get("ai_image") or {}).get("sha256") or "").lower() == new_sha), None)
                    if collision is not None:
                        raise ValueError("cross_context_raster_reuse: el mismo raster IA ya pertenece a otra noticia")
                if item.get("ai_image_regenerate_requested"):
                    old_sha = str(previous_ai.get("sha256") or item.get("ai_image_previous_sha256") or "").lower()
                    if old_sha and new_sha and old_sha == new_sha:
                        raise ValueError("La regeneración IA devolvió exactamente el mismo raster anterior")
                item["ai_image"] = holder["ai_image"]
                item["ai_image_status"] = "ready"
                item["ai_image_attempt"] = attempt
                item["ai_image_last_attempt_status"] = "ready"
                item["ai_image_last_attempt_at"] = now()
                item.pop("ai_image_failure_reason", None)
                item.pop("ai_image_regeneration_error", None)
                item["image_choice"] = "ai"
                item["image"] = dict(holder["ai_image"])
                item["image_status"] = "ready"
                item["image_pending"] = False
                item["image_app_available"] = True
                item["image_delivery"] = "app"
            except Exception as exc:
                status = "failed"
                payload["reason"] = str(exc)[:500]

        if status == "failed":
            reason = str(payload.get("reason") or "No se pudo materializar la imagen IA.")[:500]
            item["ai_image_attempt"] = attempt
            item["ai_image_last_attempt_status"] = "failed"
            item["ai_image_last_attempt_at"] = now()
            if previous_ai.get("url"):
                item["ai_image"] = previous_ai
                item["ai_image_status"] = "ready"
                item["ai_image_regeneration_error"] = reason
            else:
                item.pop("ai_image", None)
                item["ai_image_status"] = "failed"
                item["ai_image_failure_reason"] = reason
                _select_image(item)

        item.pop("ai_image_regenerate_requested", None)
        item.pop("ai_image_regenerate_requested_at", None)
        item.pop("ai_image_regenerate_request_version", None)
        path.unlink(missing_ok=True)
        for chunk_path in chunk_files:
            chunk_path.unlink(missing_ok=True)
        processed.append(eid)
        changed = True

    if changed:
        doc["updated_at"] = now()
        save(PREP, doc)
    print(json.dumps({"processed": processed, "waiting": waiting}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    raise SystemExit(main())
