"""Safe TTActualidad request for a new TTiTTulares investigation.

Only builds changes in memory. The caller validates the authenticated
repository_dispatch, records its receipt and atomically commits all files.
No Telegram sending, image generation or social publishing occurs here.
"""
from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone

IN_PROGRESS = {"PROCESSING", "UPDATE_PROCESSING"}
TERMINAL = {"published", "dismissed", "deleted"}
INSTRUCTION = (
    "Nueva investigación solicitada por TTActualidad. Verifica desde cero "
    "los hechos ACTUALES, fecha, fuentes independientes y contexto. Redacta "
    "un bloque factual nuevo, dos o tres hashtags concretos y un remate "
    "completamente nuevo. NO reutilices explicacion, tweet, remate, fuentes "
    "supuestamente contrastadas ni imagenes de la revision anterior. "
    "La noticia solo quedara READY cuando el texto haya sido verificado. "
    "Las imagenes son opcionales y nunca bloquean READY."
)


def rework_ready_news(event_id: str, revision: int, prepared: dict,
                      editorial_queue: dict, processing_mirror: dict,
                      decisions: dict, now: str | None = None):
    """Return new documents or an idempotent no-op after strict revision checks."""
    if now is None:
        now = datetime.now(timezone.utc).isoformat()
    prepared = deepcopy(prepared)
    editorial_queue = deepcopy(editorial_queue)
    processing_mirror = deepcopy(processing_mirror)
    decisions = deepcopy(decisions)

    rows = [x for x in prepared.get("items", [])
            if str(x.get("event_id") or "") == event_id]
    if len(rows) != 1:
        raise ValueError("La noticia ya no tiene una única entrada vigente en Listas")
    ready = rows[0]
    if str(ready.get("status") or "READY").upper() not in {"READY", "PREPARED"}:
        raise ValueError("La noticia ya no esta en estado READY")
    current = int(ready.get("revision") or 0)
    if current != revision:
        raise ValueError("La revision ha cambiado; actualiza TTActualidad")
    for closed in decisions.get("items", []):
        if str(closed.get("event_id") or "") == event_id and \
           str(closed.get("status") or "").lower() in TERMINAL:
            raise ValueError("La noticia tiene una decision terminal y no puede reabrirse")

    target = current + 1
    if ready.get("rewrite_pending") is True:
        if int(ready.get("rewrite_target_revision") or -1) == target and \
           ready.get("rewrite_scope") == "full" and ready.get("reinvestigate") is True:
            return None  # Already submitted against this exact old revision.
        raise ValueError("Ya existe una reelaboracion distinta pendiente")
    for row in editorial_queue.get("items", []):
        if str(row.get("event_id") or "") != event_id:
            continue
        row_revision = int(row.get("revision") or 0)
        if row_revision > current:
            raise ValueError("Ya existe una revision editorial mas reciente")
        if row_revision == current and str(row.get("status") or "").upper() in IN_PROGRESS:
            raise ValueError("La noticia sigue en elaboracion; no puede duplicarse")

    title = str(ready.get("title") or "").strip()
    if not title:
        raise ValueError("La noticia no tiene titular")
    # Preserve only stable event identity, discoverable lead and source URLs.
    # Previous facts, ratings, explanations, hashtags, remate, images and tweet
    # are neither trusted nor copied into the new investigation.
    fresh = {
        "event_id": event_id,
        "title": title,
        "url": str(ready.get("url") or ""),
        "sources": list(ready.get("sources") or []),
        "source_count": int(ready.get("source_count") or 0),
        "selected_at": now,
        "requested_at": now,
        "revision": target,
        "status": "UPDATE_PROCESSING",
        "selection_mode": "REWRITE",
        "force_user_elaborate": True,
        "manual_investigation_requested": True,
        "rewrite_pending": True,
        "rewrite_target_revision": target,
        "rewrite_scope": "full",
        "reinvestigate": True,
        "rewrite_request": INSTRUCTION,
        "preserved_editorial": None,
        "with_image": True,
        "image_mode": "ai_plus_fallback",
        "decision_source": "ttactualidad_direct_rework",
    }
    # Keep the last READY row as history/recovery, marked invisible until the
    # replacement text is materialized. An editorial run can recover the
    # request using this record even if the queue mirror is temporarily absent.
    ready.update(rewrite_pending=True, rewrite_target_revision=target,
                 rewrite_scope="full", reinvestigate=True,
                 rewrite_request=INSTRUCTION, preserved_editorial=None,
                 rewrite_requested_at=now,
                 rewrite_source="ttactualidad_direct_rework")
    # One authoritative work item per ID. Old non-active queue snapshots are
    # replaced, so the editorial agent never accidentally picks an old row.
    for doc in (editorial_queue, processing_mirror):
        doc["items"] = [x for x in doc.get("items", [])
                        if str(x.get("event_id") or "") != event_id]
        doc["items"].append(dict(fresh))
        doc["updated_at"] = now
    editorial_queue["count"] = sum(
        str(x.get("status") or "").upper() in IN_PROGRESS
        for x in editorial_queue["items"]
    )
    prepared["updated_at"] = now
    prepared["count"] = sum(not bool(x.get("rewrite_pending"))
                            for x in prepared["items"])
    return {
        "ttittulares/prepared.json": prepared,
        "ttittulares/editorial-queue.json": editorial_queue,
        "telegram/editorial-processing.json": processing_mirror,
    }
