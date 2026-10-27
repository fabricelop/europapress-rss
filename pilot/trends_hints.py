"""Pure, synthetic-testable editor-hints transition for TTActualidad trends.

Mutates the existing trends/requests.json and trends/editorial-queue.json, never a
second queue. The caller authenticates the GitHub dispatch and commits atomically.
"""
import hashlib
import unicodedata

from trends_rework import rework_explained

ACTIVE = {"preparing", "update"}
TERMINAL = {"deleted", "published", "dismissed", "removed"}


def submit_trend_hints(event_id, expected_revision, text, now, requests,
                       manual, queue, mobile, deliveries, prepared, recent):
    notes = str(text or "").strip()
    if not 8 <= len(notes) <= 6000:
        raise ValueError("Aporta entre 8 y 6000 caracteres de pistas o enlaces")
    original = next((r for r in requests.get("requests", [])
                     if str(r.get("id") or "") == event_id), None)
    old_revision = int(original.get("revision") or 0) if original else 0
    if expected_revision != old_revision:
        raise ValueError("La revisión ha cambiado; actualiza TTActualidad")
    if any(str(r.get("id") or "") == event_id and
           str(r.get("status") or "").lower() in TERMINAL
           for r in mobile.get("items", [])):
        raise ValueError("La tendencia tiene una decisión terminal")
    if original:
        if str(original.get("status") or "").lower() in TERMINAL:
            raise ValueError("La tendencia fue retirada y no puede reabrirse")
        if str(original.get("status") or "").lower() in ACTIVE:
            raise ValueError("Ya existe una investigación activa; espera su cierre")
        if any(str(r.get("id") or "") == event_id and
               str(r.get("status") or "").lower() in ACTIVE
               for r in queue.get("items", [])):
            raise ValueError("Ya hay una revisión en cola")
        if any(str(r.get("id") or "") == event_id and
               int(r.get("revision") or 0) > old_revision
               for r in queue.get("items", [])):
            raise ValueError("Hay una revisión editorial más reciente")
        name = str(original.get("name") or "").strip()
        if not name:
            raise ValueError("Falta el nombre editorial original")
        new_revision = old_revision + 1
        rank = int(original.get("rank") or 0)
    else:
        # A trend without an editorial request is allowed ONLY while in the
        # current Top 30 and with the same deterministic app-generated ID.
        current = next((r for r in (recent.get("items") or [])[:30]
                        if "manual-" + hashlib.sha256(
                            unicodedata.normalize("NFC", str(r.get("name") or "")).encode()
                        ).hexdigest()[:32] == event_id), None)
        if current is None:
            raise ValueError("Tendencia sin solicitud previa y fuera del Top 30")
        name = str(current.get("name") or "").strip()
        rank = int(current.get("rank") or 0)
        if not 1 <= rank <= 30:
            raise ValueError("La posición del radar ya no está vigente")
        new_revision = 0
        original = {"id": event_id, "created_at": now}
        requests.setdefault("requests", []).append(original)

    hints = list(original.get("user_pistas") or [])
    history = list(original.get("investigation_history") or [])
    previous_status = str(original.get("status") or "")
    if previous_status:
        history.append({
            "revision": old_revision, "status": previous_status,
            "problem_reason": str(original.get("problem_reason") or ""),
            "last_attempt_at": str(original.get("last_attempt_at") or ""),
        })
    hints.append({"at": now, "source_revision": old_revision, "text": notes,
                  "verification": "unverified_editor_context"})
    hints, history = hints[-20:], history[-20:]

    ready = next((m for m in manual.get("items", [])
                  if str(m.get("id") or "") == event_id and
                  str(m.get("status") or "").lower() == "explained"), None)
    if ready:
        # Established READY rework removes old media, old content and the old
        # ready card, while preserving the same editorial ID.
        rework_explained(event_id, old_revision, now, requests, manual, queue,
                         mobile, deliveries, "ttactualidad_editor_hints")
    else:
        # Nothing old is republished: start a clean editorial revision.
        original.clear()
        original.update({"id": event_id, "name": name, "rank": rank,
                         "created_at": now, "revision": new_revision,
                         "status": "preparing", "requested_at": now,
                         "updated_at": now, "auto_queued": False,
                         "request_source": "ttactualidad_editor_hints",
                         "reexplain": False, "rewrite_pending": False,
                         "task": "explain", "with_image": True,
                         "disable_ai_image": False, "rewrite_with_image": True,
                         "image_strategy": "ai_plus_fallback",
                         "ai_image_status": "pending",
                         "fallback_image_status": "pending",
                         "requested_together": [name]})
        queue["items"] = [r for r in queue.get("items", [])
                          if str(r.get("id") or "") != event_id]
        queue.setdefault("items", []).append({
            "id": event_id, "name": name, "rank": rank,
            "revision": new_revision, "status": "preparing",
            "requested_at": now, "auto_queued": False,
            "request_source": "ttactualidad_editor_hints",
            "task": "explain", "with_image": True, "rewrite_with_image": True})
        mobile["items"] = [r for r in mobile.get("items", [])
                           if str(r.get("id") or r.get("event_id") or "") != event_id]
        mobile["updated_at"] = now

    request = next(r for r in requests["requests"] if str(r.get("id") or "") == event_id)
    request["user_pistas"] = hints
    request["investigation_history"] = history
    request["request_source"] = "ttactualidad_editor_hints"
    request["auto_queued"] = False
    request["rank"] = rank
    request["rewrite_instruction"] = (
        "INVESTIGACIÓN NUEVA DESDE CERO. Pistas de un editor SIN verificar:\\n"
        + notes + "\\nContrasta cada dato, fecha, publicación y fuente con búsquedas "
        "independientes. Si no se verifica el detonante actual, deja el caso "
        "SIN EXPLICACIÓN VERIFICADA; nunca presentes las pistas como hechos. "
        "Si se verifica, escribe explicación factual completa y remate nuevo. "
        "No reutilices texto, remate ni imágenes de otra revisión."
    )
    request["hints_verification_status"] = "unverified"
    request["requested_at"] = now
    request["updated_at"] = now
    requests["updated_at"] = now
    queue["items"] = [r for r in queue.get("items", [])
                      if str(r.get("id") or "") != event_id or
                         int(r.get("revision") or 0) == new_revision]
    current = next(r for r in queue["items"] if str(r.get("id") or "") == event_id)
    current.update({"revision": new_revision, "rewrite_instruction": request["rewrite_instruction"],
                    "user_pistas": hints, "hints_verification_status": "unverified",
                    "status": "preparing", "auto_queued": False,
                    "requested_at": now, "request_source": "ttactualidad_editor_hints"})
    queue["count"] = sum(str(r.get("status") or "").lower() in ACTIVE
                         for r in queue["items"])
    queue["updated_at"] = now
    prepared["items"] = [r for r in prepared.get("items", [])
                         if str(r.get("id") or "") != event_id]
    prepared["count"] = len(prepared["items"])
    prepared["updated_at"] = now
    return new_revision
