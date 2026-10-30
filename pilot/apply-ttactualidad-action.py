#!/usr/bin/env python3
"""Direct TTActualidad action, without Telegram callbacks or PC listeners.
A GitHub repository_dispatch event is authenticated by GitHub before the workflow.
It is deliberately restricted to removing a currently ready item from Listas.
"""
from __future__ import annotations
import json
import os
import re
import hashlib
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from trends_rework import rework_explained, rework_top30
from trends_hints import submit_trend_hints
from rework_ttittulares import rework_ready_news

ROOT = Path(__file__).resolve().parent.parent
REQ = re.compile(r"^[A-Za-z0-9-]{12,80}$")
ID = re.compile(r"^[A-Za-z0-9:_-]{3,128}$")
TERMINAL = {"published", "deleted", "dismissed"}
LEDGER = "pilot/ttactualidad-action-receipts.json"
PUBLICATIONS = "pilot/ttactualidad-publication-events.json"


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
        # The 0.4.21 iPhone reconciles terminal outcomes by (event_id, revision).
        # Never omit revision: a decision without it looks like revision 0 and
        # leaves a revision-1 action permanently "Sin confirmar".
        existing.update({"status": status, "revision": revision, "updated_at": now,
                         "decision_source": "ttactualidad_direct"})
        decisions["updated_at"] = now
        outputs = {state_path: decisions}
        if decision == "discard":
            outputs[queue_path] = queue
            # The actual editorial outbox processor still reads this original
            # ledger, not only the compact queue. Cancel BOTH atomically.
            processing_path = "telegram/editorial-processing.json"
            processing = load(processing_path, {"items": []})
            for row in processing.get("items", []):
                if (str(row.get("event_id") or "") == event_id
                        and int(row.get("revision") or 1) == revision
                        and str(row.get("status") or "").upper()
                        in {"PROCESSING", "UPDATE_PROCESSING", "PROBLEMATIC"}):
                    row["status"] = "DISMISSED"
                    row["dismissed_at"] = now
                    row["decision_source"] = "ttactualidad_direct"
            processing["updated_at"] = now
            outputs[processing_path] = processing
        else:
            outputs[ready_path] = ready
        return outputs, "applied"

    if project == "ttendencias":
        if decision not in {"deleted", "published"}:
            fail("Decision terminal no admitida en Listas")
        terminal_status = decision
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
        if existing and str(existing.get("status") or "").lower() in TERMINAL:
            if existing["status"] != decision:
                fail("Esta tendencia ya tiene una decision final diferente")
            # A previous delete may have closed mobile only. Reconcile ALL
            # authoritative mirrors instead of returning early and allowing
            # the old card to reappear after the next GitHub refresh.

        all_manual = [row for row in manual.get("items", [])
                      if str(row.get("id") or "") == event_id]
        all_requests = [row for row in requests.get("requests", [])
                        if str(row.get("id") or "") == event_id]
        all_deliveries = [row for row in deliveries.get("items", [])
                          if str(row.get("event_id") or "") == event_id]

        # The deletion is scoped to the exact editorial revision. A newer
        # revision that is already preparing must never be overwritten.
        if any(int(row.get("revision") or 0) > revision
               for row in all_manual + all_requests):
            fail("Existe una revision editorial mas reciente; actualiza la app")

        same_manual = [row for row in all_manual
                       if int(row.get("revision") or 0) == revision]
        same_requests = [row for row in all_requests
                         if int(row.get("revision") or 0) == revision]
        if decision == "published" and any(row.get("listas_group_role") == "covered"
                                           for row in same_manual + same_requests):
            fail("Esta tendencia ya está agrupada; publica la ficha conjunta o retira la original sin publicar")
        same_delivery = [row for row in all_deliveries
                         if int(row.get("revision") or 0) == revision]
        # A READY request can exist before its explanation is copied to the
        # manual ledger. Do not mistake that temporary discrepancy for a
        # non-existent card, but never override an active or newer revision.
        queue = load("trends/editorial-queue.json", {"items": []})
        if any(str(row.get("id") or "") == event_id
               and str(row.get("status") or "").lower() in {"preparing", "update"}
               and int(row.get("revision") or 0) >= revision
               for row in queue.get("items", [])):
            fail("La tendencia sigue en elaboracion; actualiza Listas")
        if any(str(row.get("status") or "").lower() in TERMINAL
               and str(row.get("status") or "").lower() != terminal_status
               for row in same_manual + same_requests + same_delivery):
            fail("Ya existe una decision final distinta para esta revision")
        if any(str(row.get("telegram_package_status") or "").lower() in TERMINAL
               and str(row.get("telegram_package_status") or "").lower() != terminal_status
               for row in same_manual + same_requests):
            fail("El paquete editorial tiene una decision final diferente")
        prepared = load("trends/prepared.json", {"items": []})
        prepared_ready = any(
            str(item.get("id") or "") == event_id
            and int(item.get("revision") or 0) == revision
            and str(item.get("group_leader_id") or event_id) == event_id
            and str(item.get("explanation") or (item.get("primary") or {}).get("text") or "").strip()
            for item in prepared.get("items", [])
        )
        ready_requests = [row for row in same_requests
                          if str(row.get("status") or "").lower() == "ready"]
        # A signed-off ready request can be removed even when its prepared
        # snapshot was lost. That exception is DELETE-ONLY, never publication.
        ready_proof = bool(ready_requests) and (
            prepared_ready or (
                decision == "deleted" and
                any(row.get("ready_at") and
                    row.get("delivery_confirmation") == "prepared_web"
                    for row in ready_requests)
            )
        )
        legacy_delivery = next(
            (row for row in reversed(same_delivery)
             if str(row.get("status") or "").lower() == "sent"
             and row.get("final") is not False), None)

        # Do not use the *latest row by updated_at* as the sole authority:
        # for #FelizMiércoles it was already a tombstone while requests.json
        # still said explained. That mismatch made every Delete action fail.
        proof = (
            any(str(row.get("status") or "").lower() == "explained"
                and str(row.get("explanation") or "").strip()
                and str(row.get("telegram_package_status") or "").lower() not in TERMINAL
                for row in same_manual + same_requests)
            or any(str(row.get("status") or "").lower() == terminal_status
                   for row in same_manual + same_requests)
            or legacy_delivery is not None
            or ready_proof
            or (existing is not None and existing.get("status") == terminal_status
                and int(existing.get("revision") or 0) == revision)
        )
        if not proof:
            fail("La tendencia no esta en las Listas editoriales")

        now = datetime.now(timezone.utc).isoformat()
        changed = {}
        # Tombstone every duplicate snapshot of this ID+revision. Preserve
        # text, image and history, but no stale 'explained' row may resurrect
        # the card after a successful delete.
        for target in same_manual:
            target.update(status=terminal_status, telegram_package_status=terminal_status,
                          **{("published_at" if decision == "published" else "deleted_at"): now},
                          decision_source="ttactualidad_direct")
        if same_manual:
            manual["updated_at"] = now
            changed[manual_path] = manual

        for req in requests.get("requests", []):
            if str(req.get("id") or "") != event_id:
                continue
            # A newer revision is not deleted by an obsolete card.
            if int(req.get("revision") or 0) > revision:
                fail("Existe una revision editorial mas reciente; actualiza la app")
            req["status"] = terminal_status
            req["telegram_package_status"] = terminal_status
            req["published_at" if decision == "published" else "deleted_at"] = now
            req["decision_source"] = "ttactualidad_direct"
            requests["updated_at"] = now
            changed[requests_path] = requests

        if legacy_delivery and str(legacy_delivery.get("status") or "").lower() == "sent":
            check_revision(legacy_delivery, revision)
            legacy_delivery["status"] = terminal_status
            legacy_delivery["updated_at"] = now
            changed[ledger_path] = deliveries

        if not existing:
            existing = {"id": event_id}
            mobile.setdefault("items", []).append(existing)
        existing.update({"status": terminal_status, "revision": revision, "updated_at": now,
                         "source": "ttactualidad_direct"})
        mobile["updated_at"] = now
        changed[mobile_path] = mobile
        return changed, "applied"
    fail("Proyecto no reconocido")



def delete_tremending(event_id: str, revision: int):
    """Remove one Tremending card, keeping its URL in the collector checkpoint."""
    if not event_id.startswith("tremending-"):
        fail("Identificador Tremending no valido")
    path = "ttittulares/tremending/items.json"
    decisions_path = "ttittulares/decisions.json"
    state = load(path, {"items": [], "scan": {}})
    decisions = load(decisions_path, {"items": []})
    selected = find(state.get("items", []), "id", event_id)
    existing = find(decisions.get("items", []), "event_id", event_id)
    if selected is None:
        if existing and str(existing.get("status") or "").lower() == "deleted":
            return {}, "already_applied"
        fail("La entrada Tremending ya no existe; actualiza el panel")
    check_revision(selected, revision)
    if str(selected.get("status") or "").lower() in {"deleted", "dismissed", "removed"}:
        fail("La entrada Tremending ya esta eliminada")
    if existing and str(existing.get("status") or "").lower() in {"dismissed", "deleted"}:
        fail("Esta entrada tiene una decision final incompatible; actualiza el panel")
    url = str(selected.get("url") or "").strip()
    if not url.startswith("https://www.publico.es/tremending/"):
        fail("Falta URL Tremending valida; no se elimina")
    scan = state.get("scan") or {}
    # Collector ignores all scan.seen_urls, so removing the item cannot make
    # it reappear after the next source refresh.
    seen = set(scan.get("seen_urls") or [])
    seen.add(url)
    scan["seen_urls"] = sorted(seen)
    state["scan"] = scan
    state["items"] = [row for row in state["items"]
                      if str(row.get("id") or "") != event_id]
    now = datetime.now(timezone.utc).isoformat()
    state["updated_at"] = now
    state["scan"]["total_items"] = len(state["items"])
    if not existing:
        existing = {"event_id": event_id}
        decisions.setdefault("items", []).append(existing)
    existing.update({"status": "deleted", "revision": revision,
                     "updated_at": now, "decision_source": "ttactualidad_direct_tremending"})
    decisions["updated_at"] = now
    return {path: state, decisions_path: decisions}, "applied"


def apply_live(project: str, event_id: str, decision: str, revision: int, trend_name: str = '', trend_rank: int = 0, trend_hints: str = ''):
    """Live editorial decisions. Never call legacy Telegram callbacks."""
    if project == "ttittulares" and event_id.startswith("tremending-"):
        if decision != "deleted":
            fail("Tremending solo admite Quitar de Listas")
        return delete_tremending(event_id, revision)
    if decision in {"deleted", "published"}:
        return apply(project, event_id, decision, revision)
    if project == "ttittulares" and decision == "rework":
        outputs = rework_ready_news(
            event_id, revision,
            load("ttittulares/prepared.json", {"items": []}),
            load("ttittulares/editorial-queue.json", {"items": []}),
            load("telegram/editorial-processing.json", {"items": []}),
            load("ttittulares/decisions.json", {"items": []}),
        )
        return ({}, "already_applied") if outputs is None else (outputs, "applied")
    now = datetime.now(timezone.utc).isoformat()
    if project == "ttittulares":
        queue_path = "ttittulares/editorial-queue.json"
        processing_path = "telegram/editorial-processing.json"
        state_path = "ttittulares/decisions.json"
        prepared_path = "ttittulares/prepared.json"
        status_path = "ttittulares/status.json"
        queue = load(queue_path, {"items": []})
        processing = load(processing_path, {"items": []})
        decisions = load(state_path, {"items": []})
        prepared = load(prepared_path, {"items": []})
        status_doc = load(status_path, {})
        active = find(queue.get("items", []), "event_id", event_id)
        processing_active = find(processing.get("items", []), "event_id", event_id)
        existing = find(decisions.get("items", []), "event_id", event_id)
        ready = find(prepared.get("items", []), "event_id", event_id)
        source = next((row for section in ("processing_items", "problematic_items", "three_source_items")
                       for row in status_doc.get(section, [])
                       if str(row.get("event_id") or "") == event_id), None)
        if decision == "discard":
            if existing and str(existing.get("status") or "").lower() in TERMINAL:
                if str(existing["status"]).lower() == "dismissed":
                    return {}, "already_applied"
                fail("La noticia ya tiene una decision final diferente")
            # The user may have pressed Desestimar while PROCESSING and the
            # editorial worker materialized precisely that revision as READY
            # before this GitHub Actions job checked out main. Honor the
            # original discard without requiring a second tap on Listas.
            if not (source or active or ready):
                fail("La noticia ya no figura en el radar, elaboracion ni Listas")
            if ready:
                check_revision(ready, revision)
            if active and "revision" in active:
                check_revision(active, revision)
            elif source and "revision" in source:
                check_revision(source, revision)
            if processing_active and "revision" in processing_active:
                check_revision(processing_active, revision)
            if active and str(active.get("status") or "").upper() not in {
                "PROCESSING", "UPDATE_PROCESSING", "PROBLEMATIC", "READY"
            }:
                fail("La noticia ya no esta en elaboracion")
            if ready:
                prepared["items"] = [
                    row for row in prepared.get("items", [])
                    if str(row.get("event_id") or "") != event_id
                ]
                prepared["count"] = len(prepared["items"])
                prepared["updated_at"] = now
            if active:
                active["status"] = "DISMISSED"
                active["dismissed_at"] = now
                active["decision_source"] = "ttactualidad_direct"
            # Prevent a later outbox on the ORIGINAL editorial processing ledger,
            # including a READY mirror created just before the discard.
            if processing_active and str(processing_active.get("status") or "").upper() in {
                "PROCESSING", "UPDATE_PROCESSING", "PROBLEMATIC", "READY"
            }:
                processing_active["status"] = "DISMISSED"
                processing_active["dismissed_at"] = now
                processing_active["decision_source"] = "ttactualidad_direct"
            processing["updated_at"] = now
            queue["count"] = sum(str(row.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"} for row in queue.get("items", []))
            if not existing:
                existing = {"event_id": event_id}
                decisions.setdefault("items", []).append(existing)
            existing.update(status="dismissed", revision=revision, updated_at=now,
                            decision_source="ttactualidad_direct")
            decisions["updated_at"] = now
            queue["updated_at"] = now
            changes = {queue_path: queue, processing_path: processing, state_path: decisions}
            if ready:
                changes[prepared_path] = prepared
            return changes, "applied"
        if decision == "prepare":
            in_review = any(str(row.get("event_id") or "") == event_id
                            for row in status_doc.get("problematic_items", []))
            growing = next((row for row in status_doc.get("three_source_items", [])
                            if str(row.get("event_id") or "") == event_id), None)
            if active and str(active.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"}:
                check_revision(active, revision)
                if processing_active and str(processing_active.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"}:
                    check_revision(processing_active, revision)
                    return {}, "already_applied"
                # Queue is authoritative. Repair a missing/stale processing
                # mirror rather than reject a retry after the radar moved it.
                if processing_active:
                    processing_active.update(dict(active))
                else:
                    processing.setdefault("items", []).append(dict(active))
                processing["updated_at"] = now
                return {processing_path: processing}, "applied"
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
            if processing_active:
                processing_active.update(dict(fields))
            else:
                processing.setdefault("items", []).append(dict(fields))
            queue["count"] = sum(str(row.get("status") or "").upper() in {"PROCESSING", "UPDATE_PROCESSING"} for row in queue["items"])
            queue["updated_at"] = now
            processing["updated_at"] = now
            return {queue_path: queue, processing_path: processing}, "applied"
    if project == "ttendencias" and decision == "hints":
        req_path = "trends/requests.json"
        queue_path = "trends/editorial-queue.json"
        manual_path = "trends/telegram-manual-explained.json"
        mobile_path = "trends/mobile-decisions.json"
        deliveries_path = "trends/telegram-image-deliveries.json"
        prepared_path = "trends/prepared.json"
        requests = load(req_path, {"requests": []})
        queue = load(queue_path, {"items": []})
        manual = load(manual_path, {"items": []})
        mobile = load(mobile_path, {"items": []})
        deliveries = load(deliveries_path, {"items": []})
        prepared = load(prepared_path, {"items": []})
        recent = load("trends/recent.json", {"items": []})
        try:
            submit_trend_hints(event_id, revision, trend_hints, now, requests,
                               manual, queue, mobile, deliveries, prepared, recent)
        except ValueError as exc:
            fail(str(exc))
        return {
            req_path: requests, queue_path: queue, manual_path: manual,
            mobile_path: mobile, deliveries_path: deliveries,
            prepared_path: prepared,
        }, "applied"
    if project == "ttendencias" and decision == "rework":
        req_path = "trends/requests.json"
        manual_path = "trends/telegram-manual-explained.json"
        queue_path = "trends/editorial-queue.json"
        mobile_path = "trends/mobile-decisions.json"
        ledger_path = "trends/telegram-image-deliveries.json"
        prepared_path = "trends/prepared.json"
        requests = load(req_path, {"requests": []})
        manual = load(manual_path, {"items": []})
        queue = load(queue_path, {"items": []})
        mobile = load(mobile_path, {"items": []})
        deliveries = load(ledger_path, {"items": []})
        prepared = load(prepared_path, {"items": []})
        ready = next((x for x in manual.get("items", []) if str(x.get("id") or "") == event_id
                      and str(x.get("status") or "").lower() == "explained"), None)
        historical_request = find(requests.get("requests", []), "id", event_id)
        try:
            if ready and str((historical_request or {}).get("status") or "").lower() not in TERMINAL and not any(str(x.get("id") or "") == event_id and
                                 str(x.get("status") or "").lower() in TERMINAL
                                 for x in mobile.get("items", [])):
                rework_explained(event_id, revision, now, requests, manual, queue,
                                 mobile, deliveries, "ttactualidad_direct_rework")
                prepared["items"] = [row for row in prepared.get("items", [])
                                     if str(row.get("id") or "") != event_id]
            else:
                recent = load("trends/recent.json", {"items": []})
                rework_top30(event_id, revision, now, (recent.get("items") or [])[:30],
                             requests, manual, queue, mobile, "ttactualidad_direct_rework",
                             trend_name=trend_name)
        except ValueError as exc:
            fail(str(exc))
        prepared["updated_at"] = now
        return {
            req_path: requests, manual_path: manual, queue_path: queue,
            mobile_path: mobile, ledger_path: deliveries, prepared_path: prepared,
        }, "applied"
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
            # Queued snapshots may outlive a finished explanation. Do not let
            # the stale "Desestimar" button erase an already finished Listas
            # card for the same (id, revision).
            if (not request or str(request.get("status") or "").lower() not in {"preparing", "update"}
                    or int(request.get("revision") or 0) != revision):
                fail("La tendencia ya no esta En elaboracion; actualiza TTActualidad")
            manual = load("trends/telegram-manual-explained.json", {"items": []})
            if any(str(row.get("id") or "") == event_id and
                   int(row.get("revision") or 0) >= revision and
                   str(row.get("status") or "").lower() == "explained"
                   for row in manual.get("items", [])):
                fail("La tendencia ya esta en Listas; no se puede borrar desde una cola antigua")
            if not working or str(working.get("status") or "").lower() not in {"preparing", "update"}:
                fail("Esta tendencia ya no esta En elaboracion")
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
                # A Top 11-30 trend has no editorial request until the user presses Preparar.
                # Verify against the authoritative current radar, not client-supplied rank alone.
                recent = load("trends/recent.json", {"items": []})
                current = next((row for row in recent.get("items", [])
                                if str(row.get("name") or "").strip() == trend_name), None)
                if not current or not 11 <= int(current.get("rank") or 0) <= 30:
                    fail("La tendencia ya no esta entre los puestos 11 y 30")
                if int(current.get("rank") or 0) != trend_rank:
                    fail("El puesto ha cambiado; actualiza el radar")
                digest = hashlib.sha256(unicodedata.normalize("NFC", trend_name).encode("utf-8")).hexdigest()[:32]
                if event_id != "manual-" + digest:
                    fail("Identificador manual no coincide con la tendencia")
                request = {"id": event_id, "name": trend_name, "rank": trend_rank,
                           "revision": revision, "auto_queued": False, "status": "preparing",
                           "created_at": now, "requested_at": now,
                           "request_source": "ttactualidad_direct"}
                requests.setdefault("requests", []).append(request)
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
    trend_name = str(cmd.get("trend_name") or "").strip()
    trend_rank = cmd.get("trend_rank")
    trend_hints = cmd.get("hints", "")
    if project not in ("ttittulares", "ttendencias") or not ID.fullmatch(event_id) or not REQ.fullmatch(request_id):
        fail("Identificadores invalidos")
    if decision not in {"deleted", "published", "discard", "prepare", "rework", "hints"}:
        fail("Decision no admitida")
    if decision == "hints" and (project != "ttendencias" or not isinstance(trend_hints, str) or not 8 <= len(trend_hints.strip()) <= 6000):
        fail("Pistas invalidas o proyecto no admitido")
    if event_id.startswith("pilot-"):
        fail("Los casos sinteticos no pueden modificar datos editoriales")
    if type(revision) is not int or revision < 0:
        fail("Revision obligatoria, entera y no negativa")
    history = load(LEDGER, {"version": 1, "items": []})
    previous = find(history["items"], "request_id", request_id)
    if previous and str(previous.get("status") or "").lower() in {"applied", "already_applied"}:
        print("IDEMPOTENT: recibida anteriormente", previous.get("status"))
        return
    try:
        changes, status = apply_live(project, event_id, decision, revision,
                                     trend_name, trend_rank if type(trend_rank) is int else 0,
                                     trend_hints)
        rejection = ""
    except InvalidAction as exc:
        # A real validation rejection is a terminal ACK, not a GitHub outage.
        # Persist the original request_id so iPhone/Windows can stop showing
        # "Sin confirmar". Do not mutate any editorial records.
        changes, status, rejection = {}, "rejected", str(exc)[:500]
    stamp = datetime.now(timezone.utc).isoformat()
    history["items"] = [row for row in history["items"]
                         if row.get("request_id") != request_id]
    receipt = {"request_id": request_id, "project": project,
               "event_id": event_id, "revision": revision,
               "decision": decision, "status": status, "at": stamp}
    if rejection:
        receipt["error"] = rejection
    history["items"].append(receipt)
    history["items"] = history["items"][-2000:]
    if decision == "published" and status == "applied":
        # Count ONLY explicit confirmed publication confirmations from this
        # new app flow, not old "published" records from discard / Telegram.
        # GitHub server UTC timestamp is authoritative. 7-day retention
        # exceeds the 24-hour moving window by a wide safety margin.
        published = load(PUBLICATIONS, {"version": 1, "items": []})
        from datetime import timedelta
        cutoff = datetime.now(timezone.utc) - timedelta(days=7)
        rows = []
        for row in published.get("items", []):
            try:
                at = datetime.fromisoformat(str(row["at"]).replace("Z", "+00:00"))
                if at >= cutoff:
                    rows.append(row)
            except (TypeError, ValueError, KeyError):
                continue
        if not any(row.get("project") == project and
                   row.get("event_id") == event_id and
                   row.get("revision") == revision for row in rows):
            rows.append({"project": project, "event_id": event_id,
                         "revision": revision, "request_id": request_id,
                         "at": stamp})
        published["items"] = rows
        changes[PUBLICATIONS] = published
    for location, document in changes.items():
        save(location, document)
    save(LEDGER, history)
    print("TTActualidad:", status, project, decision, event_id)


if __name__ == "__main__":
    main()

