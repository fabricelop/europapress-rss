#!/usr/bin/env python3
"""Direct TTActualidad action, without Telegram callbacks or PC listeners.
A GitHub repository_dispatch event is authenticated by GitHub before the workflow.
It is deliberately restricted to removing a currently ready item from Listas.
"""
from __future__ import annotations
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQ = re.compile(r"^[A-Za-z0-9-]{12,80}$")
ID = re.compile(r"^[A-Za-z0-9:_-]{3,128}$")
TERMINAL = {"published", "deleted", "dismissed"}
LEDGER = "pilot/ttactualidad-action-receipts.json"


class InvalidAction(Exception):
    pass


def load(relative: str, default):
    p = ROOT / relative
    if relative != LEDGER and not p.is_file():
        fail("Falta el estado editorial obligatorio: " + relative)
    if not p.exists():
        return json.loads(json.dumps(default))
    return json.loads(p.read_text(encoding="utf-8"))


def save(relative: str, doc):
    path = ROOT / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def fail(msg):
    raise InvalidAction(msg)


def find(items, field, value):
    return next((r for r in items if str(r.get(field) or "") == value), None)


def check_revision(obj, expected):
    if expected is not None and int(obj.get("revision") or 0) != expected:
        fail("La revision ha cambiado; refresca TTActualidad antes de actuar")


def apply(project: str, event_id: str, decision: str, revision: int | None):
    if project == "ttittulares":
        ready_path = "ttittulares/prepared.json"
        queue_path = "ttittulares/editorial-queue.json"
        state_path = "ttittulares/decisions.json"
        ready = load(ready_path, {"items": []})
        queue = load(queue_path, {"items": []})
        decisions = load(state_path, {"items": []})
        active = find(queue.get("items", []), "event_id", event_id)
        completed = find(ready.get("items", []), "event_id", event_id)
        existing = find(decisions.get("items", []), "event_id", event_id)
        if existing and existing.get("status") in TERMINAL:
            if existing["status"] == ("dismissed" if decision == "discard" else decision):
                return {}, "already_applied"
            fail("Ya existe una decision final distinta")

        if decision in ("published", "deleted"):
            if not completed:
                fail("La noticia ya no consta en Listas")
            check_revision(completed, revision)
            status = decision
            ready["items"] = [x for x in ready["items"] if x.get("event_id") != event_id]
            ready["count"] = len(ready["items"])
        elif decision == "discard":
            if not active or str(active.get("status")) not in {"PROCESSING", "UPDATE_PROCESSING"}:
                fail("La noticia ya no esta en elaboracion")
            check_revision(active, revision)
            status = "dismissed"
            active["status"] = "DISMISSED"
            active["decision_source"] = "ttactualidad_direct"
            active["dismissed_at"] = datetime.now(timezone.utc).isoformat()
            queue["count"] = sum(str(x.get("status")) in {"PROCESSING", "UPDATE_PROCESSING"} for x in queue["items"])
        else:
            fail("Preparacion manual TTit no activa en esta fase")
        now = datetime.now(timezone.utc).isoformat()
        if not existing:
            existing = {"event_id": event_id}
            decisions.setdefault("items", []).append(existing)
        existing.update({"status": status, "updated_at": now, "decision_source": "ttactualidad_direct"})
        decisions["updated_at"] = now
        outputs = {state_path: decisions}
        if decision == "discard":
            outputs[queue_path] = queue
        else:
            outputs[ready_path] = ready
        return outputs, "applied"

    if project == "ttendencias":
        # The editorial explanation is authoritative; Telegram delivery is optional.
        manual_path = "trends/telegram-manual-explained.json"
        requests_path = "trends/requests.json"
        ledger_path = "trends/telegram-image-deliveries.json"
        mobile_path = "trends/mobile-decisions.json"
        manual = load(manual_path, {"items": []})
        requests = load(requests_path, {"requests": []})
        deliveries = load(ledger_path, {"items": []})
        mobile = load(mobile_path, {"items": []})

        existing = find(mobile.get("items", []), "id", event_id)
        if existing and existing.get("status") in TERMINAL:
            if existing["status"] == decision:
                return {}, "already_applied"
            fail("Esta tendencia ya tiene una decision final diferente")

        explained = [row for row in manual.get("items", []) if str(row.get("id") or "") == event_id]
        explained.sort(key=lambda row: (int(row.get("revision") or 0),
                                        str(row.get("updated_at") or row.get("explained_at") or "")), reverse=True)
        target = explained[0] if explained else None

        old = [row for row in deliveries.get("items", []) if str(row.get("event_id") or "") == event_id]
        old.sort(key=lambda row: (int(row.get("revision") or 0),
                                  str(row.get("updated_at") or row.get("delivered_at") or "")), reverse=True)
        legacy_delivery = old[0] if old else None

        if target:
            if (str(target.get("status") or "").lower() != "explained"
                    or not str(target.get("explanation") or "").strip()
                    or str(target.get("telegram_package_status") or "").lower() in TERMINAL):
                fail("Esta explicacion ya no esta en Listas")
            check_revision(target, revision)
        elif legacy_delivery:
            # Backward compatibility with old app versions until the editorial view ships.
            if str(legacy_delivery.get("status") or "").lower() != "sent" or legacy_delivery.get("final") is False:
                fail("La tendencia ya no esta en Listas")
            check_revision(legacy_delivery, revision)
        else:
            fail("La tendencia no esta en las Listas editoriales")

        now = datetime.now(timezone.utc).isoformat()
        changed = {}
        if target:
            target["status"] = "deleted"
            target["telegram_package_status"] = "deleted"
            target["deleted_at"] = now
            target["decision_source"] = "ttactualidad_direct"
            manual["updated_at"] = now
            changed[manual_path] = manual

        for req in requests.get("requests", []):
            if str(req.get("id") or "") != event_id:
                continue
            # A newer revision is not deleted by an obsolete card.
            if int(req.get("revision") or 0) > revision:
                fail("Existe una revision editorial mas reciente; actualiza la app")
            req["status"] = "deleted"
            req["telegram_package_status"] = "deleted"
            req["deleted_at"] = now
            req["decision_source"] = "ttactualidad_direct"
            changed[requests_path] = requests

        if legacy_delivery and str(legacy_delivery.get("status") or "").lower() == "sent" and (not target or int(legacy_delivery.get("revision") or 0) == revision):
            check_revision(legacy_delivery, revision)
            legacy_delivery["status"] = "deleted"
            legacy_delivery["updated_at"] = now
            changed[ledger_path] = deliveries

        if not existing:
            existing = {"id": event_id}
            mobile.setdefault("items", []).append(existing)
        existing.update({"status": "deleted", "revision": revision, "updated_at": now,
                         "source": "ttactualidad_direct"})
        mobile["updated_at"] = now
        changed[mobile_path] = mobile
        return changed, "applied"
    fail("Proyecto no reconocido")



def apply_live(project: str, event_id: str, decision: str, revision: int):
    """Live editorial decisions. Never call legacy Telegram callbacks."""
    if decision == "deleted":
        return apply(project, event_id, decision, revision)
    now = datetime.now(timezone.utc).isoformat()
    if project == "ttittulares":
        queue_path = "ttittulares/editorial-queue.json"
        state_path = "ttittulares/decisions.json"
        prepared_path = "ttittulares/prepared.json"
        status_path = "ttittulares/status.json"
        queue = load(queue_path, {"items": []})
        decisions = load(state_path, {"items": []})
        prepared = load(prepared_path, {"items": []})
        status_doc = load(status_path, {})
        active = find(queue.get("items", []), "event_id", event_id)
        existing = find(decisions.get("items", []), "event_id", event_id)
        ready = find(prepared.get("items", []), "event_id", event_id)
        source = next((row for section in ("processing_items", "problematic_items", "three_source_items")
                       for row in status_doc.get(section, [])
                       if str(row.get("event_id") or "") == event_id), None)
        if decision == "discard":
            if existing and str(existing.get("status") or "").lower() in TERMINAL:
                return ({}, "already_applied") if existing["status"] in {"published", "dismissed"} else fail("La noticia ya tiene otra decision terminal")
            if not (source or active or ready):
                fail("La noticia ya no figura en el radar ni en elaboracion")
            observed = active or source or ready
            if "revision" in observed:
                check_revision(observed, revision)
            if active and str(active.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING", "PROBLEMATIC"}:
                active["status"] = "PUBLISHED"
                active["published_at"] = now
                active["decision_source"] = "ttactualidad_direct"
            queue["count"] = sum(str(row.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"} for row in queue.get("items", []))
            prepared["items"] = [row for row in prepared.get("items", []) if str(row.get("event_id") or "") != event_id]
            prepared["count"] = len(prepared["items"])
            if not existing:
                existing = {"event_id": event_id}
                decisions.setdefault("items", []).append(existing)
            existing.update(status="published", revision=revision, updated_at=now, decision_source="ttactualidad_direct")
            decisions["updated_at"] = now
            queue["updated_at"] = now
            return {queue_path: queue, prepared_path: prepared, state_path: decisions}, "applied"
        if decision == "prepare":
            in_review = any(str(row.get("event_id") or "") == event_id
                            for row in status_doc.get("problematic_items", []))
            growing = next((row for row in status_doc.get("three_source_items", [])
                            if str(row.get("event_id") or "") == event_id), None)
            if active and str(active.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"}:
                check_revision(active, revision)
                return {}, "already_applied"
            if not source or not (in_review or growing):
                fail("Esta noticia ya no esta en Revision ni Creciendo")
            if "revision" in source:
                check_revision(source, revision)
            if existing and str(existing.get("status") or "").lower() in TERMINAL:
                fail("La noticia tiene una decision final; no se reabre automaticamente")
            if ready or (active and str(active.get("status") or "").upper() in
                         {"READY", "PUBLISHED", "DISMISSED", "DELETED"}):
                fail("La noticia ya fue cerrada o enviada a Listas")
            if growing:
                # The manual exception is available ONLY for an actual live
                # three-source WAITING event, not for arbitrary client IDs.
                radar = load("telegram/events.json", {"events": []})
                event = find(radar.get("events", []), "id", event_id)
                if not event or str(event.get("status") or "") not in {"WAITING", "UPDATE_WAITING"}:
                    fail("La noticia ya no esta creciendo; actualiza el panel")
                check_revision(event, revision)
                if int(event.get("source_count") or 0) != 3:
                    fail("El numero de fuentes ha cambiado; actualiza el panel")
                fields = dict(event)
                fields.update(event_id=event_id,
                              title=event.get("canonical_title") or event.get("title") or source.get("title"),
                              status="PROCESSING", selection_mode="MANUAL_GROWING_OVERRIDE",
                              force_user_elaborate=True, manual_investigation_requested=True,
                              manual_threshold_override=True, requested_at=now,
                              selected_at=now, revision=revision)
                # Three sources are enough to REQUEST investigation only.
                # No evidence is promoted to "verified" by this click.
                fields["source_count"] = 3
                fields["source_evidence"] = list(event.get("appearances") or [])
            else:
                fields = dict(source)
                fields.update(status="PROCESSING", selection_mode="MANUAL_REOPEN_OUTCOME",
                              force_user_elaborate=True, user_validated=True, user_validated_at=now,
                              revision=revision, requested_at=now, selected_at=source.get("selected_at") or now)
            if active:
                active.update(fields)
            else:
                queue.setdefault("items", []).append(fields)
            queue["count"] = sum(str(row.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"} for row in queue["items"])
            queue["updated_at"] = now
            return {queue_path: queue}, "applied"
    if project == "ttendencias":
        queue_path, req_path, mobile_path = "trends/editorial-queue.json", "trends/requests.json", "trends/mobile-decisions.json"
        queue = load(queue_path, {"items": []})
        requests = load(req_path, {"requests": []})
        mobile = load(mobile_path, {"items": []})
        working = find(queue.get("items", []), "id", event_id)
        request = find(requests.get("requests", []), "id", event_id)
        existing = find(mobile.get("items", []), "id", event_id)
        if decision == "discard":
            if existing and str(existing.get("status") or "").lower() in TERMINAL:
                return ({}, "already_applied") if existing["status"] in {"published", "dismissed"} else fail("Tendencia ya cerrada")
            if not working or str(working.get("status") or "").lower() not in {"preparing", "update", "ready", "problematic"}:
                fail("Esta tendencia ya no esta en elaboracion")
            check_revision(working, revision)
            working.update(status="published", published_at=now, decision_source="ttactualidad_direct")
            if request and int(request.get("revision") or 0) <= revision:
                request.update(status="published", published_at=now, decision_source="ttactualidad_direct")
            if not existing:
                existing = {"id": event_id}
                mobile.setdefault("items", []).append(existing)
            existing.update(status="published", revision=revision, updated_at=now, source="ttactualidad_direct")
            queue["count"] = sum(str(row.get("status") or "").lower() in {"preparing", "update"} for row in queue["items"])
            queue["updated_at"] = requests["updated_at"] = mobile["updated_at"] = now
            return {queue_path: queue, req_path: requests, mobile_path: mobile}, "applied"
        if decision == "prepare":
            if not request:
                fail("La tendencia necesita una solicitud editorial identificada")
            check_revision(request, revision)
            if existing and str(existing.get("status") or "").lower() in TERMINAL:
                fail("Tendencia cerrada; nueva revision editorial necesaria")
            if working and str(working.get("status") or "").lower() in {"preparing", "update"}:
                return {}, "already_applied"
            fields = dict(request)
            fields.update(status="preparing", revision=revision, requested_at=now,
                          request_source="ttactualidad_direct", auto_queued=False)
            if working:
                working.update(fields)
            else:
                queue.setdefault("items", []).append(fields)
            request.update(status="preparing", request_source="ttactualidad_direct",
                           auto_queued=False, requested_at=now)
            queue["count"] = sum(str(row.get("status") or "").lower() in {"preparing", "update"} for row in queue["items"])
            queue["updated_at"] = requests["updated_at"] = now
            return {queue_path: queue, req_path: requests}, "applied"
    fail("Accion no admitida para el proyecto")

def main():
    cmd = json.loads(os.environ["TT_ACTUALIDAD_EVENT_JSON"])
    project = str(cmd.get("project") or "")
    event_id = str(cmd.get("event_id") or "")
    decision = str(cmd.get("decision") or "")
    request_id = str(cmd.get("request_id") or "")
    revision = cmd.get("revision")
    if project not in ("ttittulares", "ttendencias") or not ID.fullmatch(event_id) or not REQ.fullmatch(request_id):
        fail("Identificadores invalidos")
    if decision not in {"deleted", "discard", "prepare"}:
        fail("Decision no admitida")
    if event_id.startswith("pilot-"):
        fail("Los casos sinteticos no pueden modificar datos editoriales")
    if type(revision) is not int or revision < 0:
        fail("Revision obligatoria, entera y no negativa")
    history = load(LEDGER, {"version": 1, "items": []})
    previous = find(history["items"], "request_id", request_id)
    if previous:
        print("IDEMPOTENT: recibida anteriormente", previous.get("status"))
        return
    changes, status = apply_live(project, event_id, decision, revision)
    stamp = datetime.now(timezone.utc).isoformat()
    history["items"].append({"request_id": request_id, "project": project,
                             "event_id": event_id, "revision": revision,
                             "decision": decision, "status": status, "at": stamp})
    history["items"] = history["items"][-2000:]
    for location, document in changes.items():
        save(location, document)
    save(LEDGER, history)
    print("TTActualidad:", status, project, decision, event_id)


if __name__ == "__main__":
    main()
