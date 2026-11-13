#!/usr/bin/env python3
"""Persistencia editorial V2: transiciones puras, sin red ni publicación.

La escritura en GitHub debe usar el SHA del blob leído y revalidar allí la cola.
Nunca convierte una respuesta sin contraste en ready de forma automática.
"""
import copy
import hashlib
from datetime import datetime, timezone

CAPTURED = "captured_review"
OPEN = {"pending", "review_pending"}
FINISHED = {"ready", "published", "dismissed", "cancelled"}

def _refresh(q):
    active = sorted(
        (item for item in q["items"].values()
         if item["status"] in OPEN | {"in_progress", "capture_recovery", CAPTURED}),
        key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
    q["pending_count"] = len(active)
    q["pending_ids"] = [item["trend_id"] for item in active]
    return q

def stage_capture(queue, *, trend_id, revision, answer, chat_url, validated_capture,
                  observed_at=None, lease_token=None):
    if queue.get("step") != "04_editorial_queue" or queue.get("effects_enabled") is not False:
        raise ValueError("Cola V2 inválida o efectos activos")
    item = queue.get("items", {}).get(trend_id)
    if not item or item.get("revision") != revision:
        raise ValueError("ID o revisión obsoletos")
    if item.get("status") in FINISHED:
        raise ValueError("La tendencia ya está cerrada")
    if not validated_capture or not isinstance(answer, str) or len(answer.strip()) < 80:
        raise ValueError("Captura no validada")
    if not chat_url.startswith("https://chatgpt.com/c/"):
        raise ValueError("Conversación no válida")
    text = answer.strip()
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    if item.get("status") == CAPTURED:
        saved = item.get("capture") or {}
        if saved.get("sha256") == digest and saved.get("chat_url") == chat_url:
            return copy.deepcopy(queue), "already_staged"
        raise ValueError("Conflicto: captura existente diferente")
    if item.get("status") == "capture_recovery":
        intent = item.get("send_intent") or {}
        if not lease_token or intent.get("token") != lease_token:
            raise ValueError("Recuperación de mensaje sin token de envío válido")
    elif item.get("status") == "in_progress":
        lease = item.get("lease") or {}
        if not lease.get("token") or not lease.get("worker_id"):
            raise ValueError("Reserva activa sin identidad comprobable")
        # El cierre del navegador puede haber ocurrido antes de persistir.
        # La captura solo completa la reserva identificada por el consumidor.
        if lease.get("token") != lease_token or (item.get("send_intent") or {}).get("token") != lease_token:
            raise ValueError("La reserva o el envío pertenecen a otro trabajo")
    elif item.get("status") not in OPEN:
        raise ValueError("No se puede capturar sobre este estado")
    q = copy.deepcopy(queue)
    target = q["items"][trend_id]
    target.pop("lease", None)
    target.pop("send_intent", None)
    target["status"] = CAPTURED
    target["capture"] = {
        "revision": revision, "chat_url": chat_url, "sha256": digest,
        "answer": text, "verified_complete": True,
        "editorial_validated": False,
        "captured_at": observed_at or datetime.now(timezone.utc).isoformat()
    }
    target["updated_at"] = target["capture"]["captured_at"]
    return _refresh(q), "staged_pending_editorial_review"

def mark_ready(queue, *, trend_id, revision, expected_sha256, approved_text,
               source_urls, verified_by, now=None):
    """Requiere aprobación explícita y fuentes enlazadas; no publica."""
    q = copy.deepcopy(queue)
    item = q.get("items", {}).get(trend_id)
    if not item or item.get("revision") != revision or item.get("status") != CAPTURED:
        raise ValueError("Captura/revisión no vigente")
    cap = item.get("capture") or {}
    if cap.get("sha256") != expected_sha256:
        raise ValueError("Captura sustituida")
    if not verified_by or not approved_text or len(approved_text.strip()) < 80:
        raise ValueError("Falta validación editorial")
    if not source_urls or not all(isinstance(u, str) and u.startswith("https://") for u in source_urls):
        raise ValueError("Se requieren enlaces de fuentes verificables")
    item["status"] = "ready"
    item["text"] = approved_text.strip()
    item["source_urls"] = list(source_urls)
    item["validated_by"] = verified_by
    item["completed_at"] = now or datetime.now(timezone.utc).isoformat()
    item["updated_at"] = item["completed_at"]
    del item["capture"]["answer"]  # conservar huella, no duplicar el texto
    return _refresh(q)
