#!/usr/bin/env python3
"""Pure TTActualidad V2 editorial reelaboration transitions.

No network access, no image generation, no X publication, and no V1 changes.
The GitHub Actions caller authenticates a request before using this module.
"""
import copy
import re
from datetime import datetime, timezone

ID_PATTERN = re.compile(r"^trv2-[a-f0-9]{24}$")
VALID = {"pending", "review_pending", "in_progress", "capture_recovery",
         "captured_review", "ready", "published", "dismissed", "cancelled"}
PENDING = {"pending", "review_pending", "in_progress", "capture_recovery", "captured_review"}
BUSY = {"in_progress", "capture_recovery"}
CLEAR = ("lease", "send_intent", "capture", "text", "source_urls", "validated_by",
         "completed_at", "capture_recovery_reason", "image", "ai_image",
         "image_status", "image_pending", "previous_explanation")


def utcnow():
    return datetime.now(timezone.utc).isoformat()


def validate(queue, trend_id, expected_revision):
    if (queue.get("step") != "04_editorial_queue"
        or queue.get("effects_enabled") is not False
        or queue.get("country") != "ES"):
        raise ValueError("La cola no es la V2 aislada")
    if not isinstance(trend_id, str) or not ID_PATTERN.fullmatch(trend_id):
        raise ValueError("Identificador de tendencia invalido")
    row = (queue.get("items") or {}).get(trend_id)
    if not row or row.get("trend_id") != trend_id:
        raise ValueError("ID V2 no encontrado")
    if type(expected_revision) is not int or expected_revision < 1:
        raise ValueError("Revision solicitada invalida")
    if row.get("status") not in VALID:
        raise ValueError("Estado desconocido")
    if row.get("revision") != expected_revision:
        raise ValueError("La revision ya ha cambiado; no duplicar")
    return row


def request(queue, *, trend_id, expected_revision, issue_number, requested_by, now=None):
    """Remember E from ANY status, without touching active ChatGPT sessions."""
    row = validate(queue, trend_id, expected_revision)
    if type(issue_number) is not int or issue_number <= 0 or requested_by != "fabricelop":
        raise ValueError("Solicitud no autorizada o issue invalida")
    old = row.get("reelaboration_requested")
    if old is not None:
        if old.get("expected_revision") != expected_revision:
            raise ValueError("Peticion anterior incongruente")
        return copy.deepcopy(queue), "already_requested"
    out = copy.deepcopy(queue)
    target = out["items"][trend_id]
    target["reelaboration_requested"] = {
        "expected_revision": expected_revision, "issue_number": issue_number,
        "requested_by": requested_by, "requested_at": now or utcnow(),
    }
    return out, "recorded"


def apply(queue, *, trend_id, now=None):
    """Apply E when the previous send is fully settled; never clobber a lease."""
    if queue.get("step") != "04_editorial_queue" or queue.get("effects_enabled") is not False:
        raise ValueError("No es una cola segura V2")
    original = (queue.get("items") or {}).get(trend_id)
    if not original or not original.get("reelaboration_requested"):
        return copy.deepcopy(queue), "no_request"
    req = original["reelaboration_requested"]
    if req.get("expected_revision") != original.get("revision"):
        raise ValueError("Peticion obsoleta: revision distinta")
    if (original.get("status") in BUSY
        or original.get("lease") or original.get("send_intent")):
        return copy.deepcopy(queue), "deferred_active_chat"
    if original.get("status") not in VALID:
        raise ValueError("Estado original desconocido")
    stamp = now or utcnow()
    out = copy.deepcopy(queue)
    row = out["items"][trend_id]
    archive = list(row.get("revision_history") or [])
    prior = {k: copy.deepcopy(v) for k, v in row.items()
             if k not in ("revision_history", "reelaboration_requested")}
    prior["archived_at"] = stamp
    prior["reelaboration_issue"] = req["issue_number"]
    archive.append(prior)
    row["revision_history"] = archive
    row["revision"] = int(row["revision"]) + 1
    row["status"] = "review_pending"
    row["reason"] = "manual_reelaboration_from_zero"
    row["requested_at"] = stamp
    row["updated_at"] = stamp
    row["attempts"] = 0
    row["previous_reelaboration_issue"] = req["issue_number"]
    for key in CLEAR + ("reelaboration_requested",):
        row.pop(key, None)
    active = sorted((x for x in out["items"].values()
                     if x["status"] in PENDING),
                    key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
    out["pending_ids"] = [x["trend_id"] for x in active]
    out["pending_count"] = len(active)
    return out, "applied"
