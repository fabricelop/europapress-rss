"""Solicitud RE V2: reinicio editorial, sin reutilizar texto ni imagen.

Solo transforma una copia de la cola aislada y no publica contenido.
"""

from copy import deepcopy


DISPLAYED = {"captured_review", "ready", "published"}


def request_reexplanation(queue, history, *, trend_id, base_revision, entered_top30_at, requested_at, mode="standard", hints=""):
    """RE or RE-X; hints are user-supplied search leads, not verified facts."""
    if mode not in {"standard", "x"}:
        raise ValueError("Modalidad RE incorrecta")
    if mode == "x":
        if not isinstance(hints, str) or not 10 <= len(hints.strip()) <= 1200:
            raise ValueError("RE-X necesita pistas de 10 a 1200 caracteres")
        hints = hints.strip()
    elif hints:
        raise ValueError("RE ordinaria no acepta pistas")
    if (queue.get("step") != "04_editorial_queue"
            or queue.get("effects_enabled") is not False
            or history.get("step") != "03_movement"
            or history.get("country") != "ES"
            or queue.get("source_observed_at") != history.get("observed_at")):
        raise ValueError("Estado V2 sin correspondencia temporal")
    topics = history.get("topics") or {}
    # A deliberately requested RE remains valid after the trend leaves Top30.
    # The stable identity must still exist in our historical topic registry.
    matching = [topic for topic in topics.values()
                if topic.get("trend_id") == trend_id]
    if len(matching) != 1:
        raise ValueError("La tendencia no pertenece al historial V2")
    topic = matching[0]
    # El reloj Cloudflare y el de GitHub atribuyen fechas de entrada distintas.
    # Esta diferencia no puede bloquear una solicitud explícita ni cambiar el ID.
    if not isinstance(entered_top30_at, str) or not entered_top30_at:
        raise ValueError("Falta fecha informativa de entrada")
    old = (queue.get("items") or {}).get(trend_id)
    if not old or old.get("trend_id") != trend_id:
        raise ValueError("Identidad editorial incorrecta")
    revision = old.get("revision")
    if not isinstance(revision, int) or not isinstance(base_revision, int) or base_revision < 1:
        raise ValueError("Revisión inválida")
    if revision > base_revision:
        # El mismo RE fue procesado ya: evitar cualquier duplicación.
        return deepcopy(queue), "ALREADY_APPLIED"
    if revision != base_revision or old.get("status") not in DISPLAYED:
        raise ValueError("La revisión editorial ha cambiado o no está explicada")
    if not isinstance(requested_at, str) or not requested_at:
        raise ValueError("Fecha de solicitud no válida")
    copy = deepcopy(queue)
    item = copy["items"][trend_id]
    # La revisión previa sigue en el historial de Git, pero no en la cola activa:
    # ni su imagen ni su texto deben aparecer durante el nuevo proceso editorial.
    for key in ("previous_revision", "previous_status", "previous_capture",
                "previous_explanation"):
        item.pop(key, None)
    item["revision"] = base_revision + 1
    item["status"] = "review_pending"
    item["reason"] = "user_reexplanation"
    item["review_mode"] = mode
    if mode == "x":
        item["review_hints"] = hints
    else:
        item.pop("review_hints", None)
    # New revision gets a fresh retry budget; failures of the old explanation
    # must not silently make the user-requested revision ineligible.
    item["attempts"] = 0
    item["requested_at"] = requested_at
    item["updated_at"] = requested_at
    item.pop("capture", None)
    item.pop("text", None)
    item.pop("completed_at", None)
    item.pop("lease", None)
    pending = sorted((x for x in copy["items"].values() if x.get("status")
                     in {"pending", "review_pending", "in_progress", "captured_review", "capture_recovery"}),
                     key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
    copy["pending_ids"] = [x["trend_id"] for x in pending]
    copy["pending_count"] = len(pending)
    return copy, "ENQUEUED"
