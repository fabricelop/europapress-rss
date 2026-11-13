#!/usr/bin/env python3
"""Selección y verificación para el consumidor secuencial V2.

Funciones puras, reutilizables y sin operaciones externas.
"""
import hashlib

OPEN = {"pending", "review_pending"}

def eligible_items(queue, limit):
    if queue.get("step") != "04_editorial_queue" or queue.get("effects_enabled") is not False:
        raise ValueError("Cola V2 inválida o publicaciones habilitadas")
    if not isinstance(limit, int) or not 1 <= limit <= 3:
        raise ValueError("Límite fuera de 1..3")
    items = queue.get("items")
    if not isinstance(items, dict):
        raise ValueError("Estructura de cola incorrecta")
    filtered = [
        x for x in items.values()
        if x.get("status") in OPEN
        and not x.get("send_intent")
        and not x.get("capture")
        and not x.get("lease")
        and int(x.get("attempts", 0)) < 3
    ]
    filtered.sort(key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
    return filtered[:limit]

def verify_persisted(queue, journal):
    if queue.get("effects_enabled") is not False:
        raise ValueError("Efectos habilitados: detener")
    if not journal.get("persisted") or not journal.get("cleanup_verified"):
        raise ValueError("Diario no confirma persistencia y cierre")
    if journal.get("remaining_v2_pids"):
        raise ValueError("Chrome V2 no se cerró")
    if not journal.get("reply_captured") or not journal.get("message_sent"):
        raise ValueError("Respuesta/envío sin confirmar")
    item = queue.get("items", {}).get(journal.get("trend_id"), {})
    if item.get("revision") != journal.get("revision") or item.get("status") != "captured_review":
        raise ValueError("No existe captura vigente en GitHub")
    cap = item.get("capture") or {}
    answer = journal.get("answer")
    if not isinstance(answer, str) or len(answer.strip()) < 80:
        raise ValueError("Respuesta insuficiente")
    digest = hashlib.sha256(answer.strip().encode("utf-8")).hexdigest()
    if (cap.get("sha256") != digest or cap.get("chat_url") != journal.get("chat_url")
        or cap.get("answer") != answer.strip()
        or cap.get("verified_complete") is not True
        or cap.get("editorial_validated") is not False):
        raise ValueError("Captura guardada no coincide con el diario")
    if item.get("send_intent") or item.get("lease"):
        raise ValueError("Reserva no liberada")
    return digest
