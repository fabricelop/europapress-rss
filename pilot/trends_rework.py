"""Reelaboración de una tendencia ya en Listas, sin reutilizar texto ni medios previos.

Pure mutation shared by TTActualidad Worker direct actions and GitHub Pages Issues.
The caller is responsible for authenticated request and atomic Git commit.
"""
from __future__ import annotations

def rework_explained(event_id, expected_revision, now, requests, manual, queue, mobile, deliveries, source):
    def error(message):
        raise ValueError(message)

    old = sorted(
        (x for x in manual.get("items", []) if str(x.get("id") or "") == event_id),
        key=lambda x: (int(x.get("revision") or 0), str(x.get("explained_at") or "")),
        reverse=True,
    )
    current = old[0] if old else None
    request = next((x for x in requests.get("requests", [])
                    if str(x.get("id") or "") == event_id), None)
    if not current or str(current.get("status") or "").lower() != "explained" or not str(current.get("explanation") or "").strip():
        error("La tendencia ya no figura en Listas; actualiza el panel")
    if str(current.get("telegram_package_status") or "").lower() in {"deleted", "dismissed", "published", "removed"}:
        error("La tendencia ya fue cerrada")
    if request is None:
        error("La solicitud editorial original ya no existe")
    revision = int(current.get("revision") or 0)
    if expected_revision is not None and revision != expected_revision:
        error("La revisión ha cambiado; actualiza TTActualidad")
    if int(request.get("revision") or 0) != revision:
        error("Ya existe una revisión más reciente; actualiza TTActualidad")
    if str(request.get("status") or "").lower() in {"preparing", "update"}:
        error("La tendencia ya se encuentra En elaboración")
    active = next((x for x in queue.get("items", []) if str(x.get("id") or "") == event_id
                   and str(x.get("status") or "").lower() in {"preparing", "update"}), None)
    if active:
        error("Ya hay una reelaboración pendiente para esta tendencia")
    grouped = current.get("grouped_member_revisions") or []
    if any(str(x.get("id") or "") != event_id for x in grouped if isinstance(x, dict)):
        error("Esta tarjeta agrupa varias tendencias; hay que separarlas antes de reelaborarla")

    next_revision = revision + 1
    title = str(current.get("name") or request.get("name") or "").strip()
    if not title:
        error("Tendencia sin nombre verificable")

    # Do not keep the previous ready text/image card. It must disappear from
    # Listas immediately after the GitHub commit; a new revision starts blank.
    manual["items"] = [x for x in manual.get("items", [])
                       if str(x.get("id") or "") != event_id]
    manual["updated_at"] = now

    # Old Telegram legacy media must never count as the new editorial revision.
    for entry in deliveries.get("items", []):
        if str(entry.get("event_id") or "") == event_id and int(entry.get("revision") or 0) <= revision:
            if str(entry.get("status") or "").lower() == "sent":
                entry["status"] = "superseded"
                entry["updated_at"] = now
    deliveries["updated_at"] = now

    # Retain only identity, explicit new request configuration and revision.
    # In particular purge all prior explanation, sources, group and media.
    preserve = {k: request.get(k) for k in ("id", "created_at") if request.get(k) is not None}
    request.clear()
    request.update(preserve)
    request.update({
        "id": event_id, "name": title,
        "rank": int(current.get("rank") or current.get("rank_at_explanation") or 0),
        "revision": next_revision, "status": "preparing",
        "requested_at": now, "updated_at": now, "reexplain": False,
        "rewrite_pending": False, "task": "explain", "auto_queued": False,
        "request_source": source, "with_image": True,
        "disable_ai_image": False, "rewrite_with_image": True,
        "image_strategy": "ai_plus_fallback", "image_choice": "none",
        "image_pending": True, "fallback_image_status": "pending",
        "ai_image_status": "pending",
        "requested_together": [title],
        "rewrite_instruction": (
            "Elaboración desde cero por información desfasada. Investiga hechos y "
            "marcador o resultado ACTUALES antes de escribir. Redacta un texto factual "
            "nuevo y un remate nuevo. Busca y valida una foto de archivo nueva "
            "para esta revisión. No reutilices texto, remate ni imágenes de revisiones anteriores."
        ),
    })
    requests["updated_at"] = now

    queue["items"] = [x for x in queue.get("items", []) if str(x.get("id") or "") != event_id]
    queue["items"].append({
        "id": event_id, "name": title, "rank": request["rank"],
        "revision": next_revision, "status": "preparing",
        "requested_at": now, "task": "explain", "auto_queued": False,
        "request_source": source, "with_image": True,
        "disable_ai_image": False, "rewrite_with_image": True,
        "image_strategy": "ai_plus_fallback",
        "fallback_image_status": "pending",
        "rewrite_instruction": request["rewrite_instruction"],
    })
    queue["count"] = sum(str(x.get("status") or "").lower() in {"preparing", "update"}
                         for x in queue["items"])
    queue["updated_at"] = now

    # A prior mobile decision cannot hide the new work in 'En elaboración'.
    mobile["items"] = [x for x in mobile.get("items", [])
                       if str(x.get("id") or x.get("event_id") or "") != event_id]
    mobile["updated_at"] = now
    return next_revision

def rework_top30(event_id, expected_revision, now, current_top30, requests, manual, queue, mobile, source):
    """Manual fresh investigation of a previously explained Top-30 label.

    Unlike Listas, this also covers an old deleted editorial card or a grouped
    member with no independent ready card. No prior image/text is reused.
    """
    import hashlib
    import unicodedata

    def key(value):
        value = unicodedata.normalize("NFD", str(value or "").strip().casefold())
        return "".join(ch for ch in value if unicodedata.category(ch) != "Mn")

    old = next((x for x in requests.get("requests", []) if str(x.get("id") or "") == event_id), None)
    if not old:
        raise ValueError("No existe un registro editorial anterior verificable")
    if expected_revision is not None and int(old.get("revision") or 0) != expected_revision:
        raise ValueError("La revisión ha cambiado; actualiza TTActualidad")
    name = str(old.get("name") or "").strip()
    rank_row = next((x for x in current_top30 if key(x.get("name")) == key(name)), None)
    if not rank_row:
        raise ValueError("La tendencia ya no está en el Top 30 actual")
    if str(old.get("status") or "").lower() in {"preparing", "update", "problematic"}:
        raise ValueError("La tendencia ya está en elaboración")
    eligible = bool(old.get("explanation")) or any(
        str(x.get("explanation") or "").strip() and
        (str(x.get("id") or "") == event_id or
         key(name) in {key(z) for z in x.get("trend_names") or []})
        for x in manual.get("items", [])
    )
    if not eligible:
        raise ValueError("La tendencia aún no tiene una explicación anterior; usa Preparar novedad")
    if any(key(x.get("name")) == key(name) and
           str(x.get("status") or "").lower() in {"preparing", "update"}
           for x in requests.get("requests", [])):
        raise ValueError("Ya existe una elaboración más reciente de esta tendencia")

    # A new ID avoids immutable terminal closure by an old deleted package.
    new_id = hashlib.sha256(("manual-rework|" + event_id + "|" + now).encode("utf-8")).hexdigest()[:12]
    row = {
        "id": new_id, "name": name, "rank": int(rank_row.get("rank") or 0),
        "revision": 0, "status": "preparing",
        "created_at": now, "requested_at": now, "updated_at": now,
        "task": "explain", "auto_queued": False, "request_source": source,
        "with_image": True, "disable_ai_image": False, "rewrite_with_image": True,
        "image_strategy": "ai_plus_fallback", "fallback_image_status": "pending",
        "ai_image_status": "pending", "requested_together": [name],
        "originated_from_prior_id": event_id,
        "rewrite_instruction": (
            "Investigación desde cero: verifica el contexto ACTUAL de " + name +
            ", eventos, marcador y fecha. Redacta texto y remate nuevos y consigue "
            "una nueva foto de archivo para esta revisión. No reutilices explicaciones "
            "ni imágenes de una versión ya publicada o cerrada."
        )
    }
    requests.setdefault("requests", []).append(row)
    requests["updated_at"] = now
    queue.setdefault("items", []).append(dict(row))
    queue["count"] = sum(str(x.get("status") or "").lower() in {"preparing", "update"} for x in queue["items"])
    queue["updated_at"] = now
    mobile["updated_at"] = now
    return new_id
