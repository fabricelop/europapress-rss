"""Solicitud RE V2: nueva revisión sin ocultar la edición ya visible.

Solo transforma una copia de la cola aislada y no publica contenido.
"""

from copy import deepcopy


DISPLAYED = {"captured_review", "ready", "published"}


def request_reexplanation(queue, history, *, trend_id, base_revision, entered_top30_at, requested_at):
    if (queue.get("step") != "04_editorial_queue"
            or queue.get("effects_enabled") is not False
            or history.get("step") != "03_movement"
            or history.get("country") != "ES"
            or queue.get("source_observed_at") != history.get("observed_at")):
        raise ValueError("Estado V2 sin correspondencia temporal")
    topics = history.get("topics") or {}
    matching = [topic for topic in topics.values()
                if topic.get("trend_id") == trend_id and topic.get("active") is True
                and isinstance(topic.get("rank"), int) and 1 <= topic["rank"] <= 30]
    if len(matching) != 1:
        raise ValueError("La tendencia ya no está en el Top30")
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
    item["previous_revision"] = base_revision
    item["previous_status"] = old["status"]
    item["previous_capture"] = deepcopy(old.get("capture") or {})
    item["previous_explanation"] = {
        "revision": base_revision,
        "status": old["status"],
        "completed_at": old.get("completed_at"),
        "text": old.get("text"),
    }
    item["revision"] = base_revision + 1
    item["status"] = "review_pending"
    item["reason"] = "user_reexplanation"
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
