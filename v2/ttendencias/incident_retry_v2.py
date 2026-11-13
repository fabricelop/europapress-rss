#!/usr/bin/env python3
"""Retry V2 incidents as a NEW revision, never resend the previous one.

Pure state transitions. The caller must confirm no V2 Chrome is running,
must try recovering a known sent conversation first, and use GitHub SHA CAS.
"""
import copy
from datetime import datetime, timedelta, timezone

MAX_INCIDENT_RETRIES = 2
GRACE_MINUTES = 8
INCIDENT_STATUSES = frozenset(("in_progress", "capture_recovery"))
ACTIVE = frozenset(("pending", "review_pending", "in_progress", "capture_recovery", "captured_review"))


def moment(value):
    if not isinstance(value, str) or not value:
        raise ValueError("Falta fecha de incidencia")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Fecha sin zona horaria")
    return parsed.astimezone(timezone.utc)


def eligible_incident(item, *, now=None):
    """Incident has aged out and is not a currently leased/active response."""
    if item.get("status") not in INCIDENT_STATUSES:
        return False
    if int(item.get("incident_retries", 0)) >= MAX_INCIDENT_RETRIES:
        return False
    if (item.get("capture") or {}).get("verified_complete") is True:
        return False
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("Reloj sin zona horaria")
    try:
        if item["status"] == "in_progress":
            lease = item.get("lease") or {}
            if not lease.get("expires_at"):
                return False
            threshold = moment(lease["expires_at"])
        else:
            threshold = moment(item.get("updated_at"))
    except (TypeError, ValueError):
        return False
    return now.astimezone(timezone.utc) >= threshold + timedelta(minutes=GRACE_MINUTES)


def ranked_incident(queue, history, *, now=None):
    """Pick the highest-ranked eligible incident ONLY in current fresh Top30."""
    from select_current_top30_v2 import select_current_top30
    # Validation also rejects stale/mismatched history, before any change.
    _ranked, age = select_current_top30(queue, history, 30, now=now)
    for rank, name in enumerate(history["top30"], 1):
        topic = next((t for t in history["topics"].values()
                      if t.get("active") is True and t.get("rank") == rank
                      and t.get("name") == name), None)
        if not topic:
            raise ValueError("Rank incoherente")
        item = queue["items"].get(topic["trend_id"])
        if item and eligible_incident(item, now=now):
            return item, age
    return None, age


def restart_as_new_revision(queue, trend_id, *, now=None, chrome_clear=False,
                            recovery_checked=False, previous_chat_url=""):
    """Return a fresh PENDING revision, preserving evidence of every attempt.

    Explicit guard from the caller: no current V2 browser; attempted to recover
    an existing sent chat, or proved there was no message to recover.
    """
    if queue.get("step") != "04_editorial_queue" or queue.get("effects_enabled") is not False:
        raise ValueError("La cola no es V2 segura")
    if not chrome_clear or not recovery_checked:
        raise ValueError("No reiniciar: falta cierre de Chrome o comprobación de rescate")
    original = (queue.get("items") or {}).get(trend_id)
    if not original or not eligible_incident(original, now=now):
        raise ValueError("Incidencia no recuperable todavía o agotó reintentos")
    now = now or datetime.now(timezone.utc)
    iso = now.astimezone(timezone.utc).isoformat()
    output = copy.deepcopy(queue)
    row = output["items"][trend_id]
    archive = list(row.get("previous_attempts") or [])
    archive.append({
        "revision": row["revision"],
        "status": row["status"],
        "attempts": row.get("attempts", 0),
        "chat_url": previous_chat_url or (row.get("capture") or {}).get("chat_url"),
        "started_at": (row.get("lease") or {}).get("started_at"),
        "send_intent_at": (row.get("send_intent") or {}).get("at"),
        "incident_reason": row.get("capture_recovery_reason") or "lease_expired_without_capture",
        "archived_at": iso,
    })
    row["previous_attempts"] = archive[-MAX_INCIDENT_RETRIES:]
    row["revision"] = int(row["revision"]) + 1
    row["incident_retries"] = int(row.get("incident_retries", 0)) + 1
    row["status"] = "pending"
    row["reason"] = "retry_after_incident"
    row["requested_at"] = iso
    row["updated_at"] = iso
    row["attempts"] = 0
    for key in ("lease", "send_intent", "capture", "capture_recovery_reason",
                "completed_at", "text"):
        row.pop(key, None)
    pending = sorted((v for v in output["items"].values()
                      if v.get("status") in ACTIVE),
                     key=lambda v: (v.get("requested_at", ""), v["trend_id"]))
    output["pending_ids"] = [v["trend_id"] for v in pending]
    output["pending_count"] = len(pending)
    return output
