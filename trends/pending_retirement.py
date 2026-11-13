"""Retire one pending editorial occurrence without blacklisting its trend name.

Only an observed NEW Top30 entry after retirement permits automatic re-entry.
Historic editorial results and publication decisions are never changed.
"""
from __future__ import annotations

import unicodedata
from datetime import datetime


def key(value):
    folded = unicodedata.normalize("NFD", str(value or "").casefold().strip())
    return " ".join(c for c in folded if unicodedata.category(c) != "Mn").lstrip("#")


def instant(value):
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else None
    except (ValueError, TypeError):
        return None


def matching_radar_item(recent, name):
    return next((row for row in recent.get("items", [])[:30]
                 if key(row.get("name")) == key(name)), None)


def current_retirement(name, radar_item, records):
    """Return latest retirement unless a genuine newer Top30 entry is proven.

    An updated ranking, a later scrape, or merely remaining inside the Top30
    never undoes an editorial removal.
    """
    relevant = [r for r in records if key(r.get("name")) == key(name)]
    if not relevant:
        return None
    latest = max(relevant, key=lambda r: str(r.get("retired_at") or ""))
    retired = instant(latest.get("retired_at"))
    entered = instant((radar_item or {}).get("entered_top30_at"))
    if retired and entered and entered > retired:
        return None
    return latest


def retire_pending(requests_doc, queue_doc, recent_doc, retirements_doc,
                   element_id, revision, now, name_hint=""):
    """Mutate only one matching pending ID+revision, keeping existing history.

    Returns an applied/already_applied receipt. Refuse stale card revisions,
    explained/published cards, or arbitrary labels absent from source data.
    """
    if revision is None or int(revision) < 0:
        raise ValueError("La revisión editorial es obligatoria")
    revision = int(revision)
    item_id = str(element_id or "").strip()
    name_hint = str(name_hint or "").strip()
    requests = requests_doc.setdefault("requests", [])
    queue = queue_doc.setdefault("items", [])
    exact = [r for r in requests if str(r.get("id") or "") == item_id]
    if exact:
        target = max(exact, key=lambda r: int(r.get("revision") or 0))
        if int(target.get("revision") or 0) != revision:
            raise ValueError("Revisión obsoleta: actualizar Pendientes")
    else:
        # A historic V1 page may submit a literal name. Resolve it only
        # against an unambiguous active pending request.
        candidates = [r for r in requests
                      if key(r.get("name")) == key(item_id or name_hint)
                      and str(r.get("status") or "").lower() in
                         {"preparing", "update", "problematic", "ready", "pending", "inactive"}]
        if len(candidates) == 1:
            target = candidates[0]
            if int(target.get("revision") or 0) != revision:
                raise ValueError("Revisión obsoleta: actualizar Pendientes")
        else:
            target = None

    if target is not None:
        status = str(target.get("status") or "").lower()
        if status not in {"preparing", "update", "problematic", "ready", "pending", "inactive"}:
            raise ValueError("No es una tendencia pendiente; no se borrará su publicación")
        name = str(target.get("name") or name_hint or "").strip()
        canonical_id = str(target.get("id") or item_id)
    else:
        # Permit a radar-only pending card, but never an arbitrary/off-list
        # name or one with an already completed editorial request.
        radar = matching_radar_item(recent_doc, name_hint or item_id)
        if not radar:
            raise ValueError("La tendencia no figura en Pendientes actuales")
        name = str(radar.get("name") or "").strip()
        canonical_id = item_id
        if any(key(r.get("name")) == key(name) and
               str(r.get("status") or "").lower() in
               {"explained", "published", "deleted", "dismissed", "removed"}
               for r in requests):
            raise ValueError("La tendencia ya tiene decisión editorial; no se retira como pendiente")

    if not name:
        raise ValueError("Nombre de tendencia vacío")
    records = retirements_doc.setdefault("items", [])
    previous = next((r for r in records
                     if str(r.get("id") or "") == canonical_id
                     and int(r.get("revision") or 0) == revision), None)
    if previous:
        # Repair any stale queue mirror idempotently.
        queue_doc["items"] = [row for row in queue if not (
            str(row.get("id") or "") == canonical_id and
            int(row.get("revision") or 0) == revision)]
        queue_doc["count"] = len(queue_doc["items"])
        return "already_applied"

    radar = matching_radar_item(recent_doc, name)
    records.append({"id": canonical_id, "revision": revision, "name": name,
                    "retired_at": now,
                    "entered_top30_at": (radar or {}).get("entered_top30_at")})
    retirements_doc["updated_at"] = now
    if target is not None:
        target.update(status="inactive", inactive_reason="editor_retired_current_occurrence",
                      retired_at=now, reexplain=False, rewrite_pending=False,
                      with_image=False, disable_ai_image=True)
        requests_doc["updated_at"] = now
    queue_doc["items"] = [row for row in queue
                          if not (str(row.get("id") or "") == canonical_id and
                                  int(row.get("revision") or 0) == revision)]
    queue_doc["count"] = len(queue_doc["items"])
    queue_doc["updated_at"] = now
    return "applied"
