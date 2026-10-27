#!/usr/bin/env python3
"""Atomic and idempotent TTActualidad multi-selection commands.

The runner starts from fresh main and commits only after every existing
single-item revision check has succeeded. No partial batch is ever pushed.
"""
from __future__ import annotations
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from apply_ttactualidad_action import apply_live, load, save

ROOT = Path(__file__).resolve().parents[1]
RECEIPTS = "pilot/ttactualidad-batch-receipts.json"
UUID = re.compile(r"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", re.I)
IDENTIFIER = re.compile(r"^[a-zA-Z0-9:_-]{3,128}$")
MAX_ITEMS = 12


def validate(payload):
    if not isinstance(payload, dict):
        raise ValueError("Solicitud no válida")
    request_id = payload.get("request_id")
    project, decision = payload.get("project"), payload.get("decision")
    if not isinstance(request_id, str) or not UUID.fullmatch(request_id):
        raise ValueError("Identificador de lote inválido")
    if project not in {"ttittulares", "ttendencias"}:
        raise ValueError("Proyecto no válido")
    if decision not in ({"deleted", "rework"} if project == "ttendencias"
                        else {"deleted", "discard", "prepare"}):
        raise ValueError("Decisión no permitida para el proyecto")
    items = payload.get("items")
    if not isinstance(items, list) or not (2 <= len(items) <= MAX_ITEMS):
        raise ValueError("Selecciona entre dos y doce elementos")
    identifiers = set()
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("Elemento no válido")
        eid, revision, rank = item.get("event_id"), item.get("revision"), item.get("rank", 0)
        if not isinstance(eid, str) or not IDENTIFIER.fullmatch(eid):
            raise ValueError("ID editorial no válido")
        if type(revision) is not int or not 0 <= revision <= 100000:
            raise ValueError("Revisión no válida")
        if type(rank) is not int or not 0 <= rank <= 30:
            raise ValueError("Posición no válida")
        if eid in identifiers:
            raise ValueError("No se pueden repetir identificadores")
        identifiers.add(eid)
        if not isinstance(item.get("title"), str) or not 1 <= len(item["title"].strip()) <= 160:
            raise ValueError("Cada elemento necesita nombre")
    topic = str(payload.get("group_topic") or "").strip()
    if decision == "rework" and not (4 <= len(topic) <= 160):
        raise ValueError("Indica el tema común de estas tendencias")
    return request_id, project, decision, items, topic


def group_requests(request_id, items, topic, new_requests_before, stamp):
    """Attach one shared research request without merging distinct identities."""
    req_path, queue_path = "trends/requests.json", "trends/editorial-queue.json"
    req = load(req_path, {"requests": []})
    queue = load(queue_path, {"items": []})
    old_ids = set(new_requests_before)
    selected = {i["event_id"] for i in items}
    matching = []
    for row in req.get("requests", []):
        if str(row.get("status") or "").lower() != "preparing":
            continue
        rid = str(row.get("id") or "")
        if rid in selected or (rid not in old_ids and
                               str(row.get("originated_from_prior_id") or "") in selected):
            matching.append(row)
    if len(matching) != len(items):
        raise ValueError("No se han encontrado todas las revisiones del lote")
    names = [str(row.get("name") or "").strip() for row in matching]
    if any(not name for name in names):
        raise ValueError("Alguna tendencia no tiene nombre verificable")
    identity = [
        {"id": str(row["id"]), "revision": int(row.get("revision") or 0),
         "origin": str(row.get("originated_from_prior_id") or row["id"])}
        for row in matching
    ]
    ids = {row["id"] for row in matching}
    for row in matching:
        row["requested_together"] = names
        row["group_topic"] = topic
        row["group_request_id"] = request_id
        row["group_members"] = identity
        row["rewrite_instruction"] = (
            str(row.get("rewrite_instruction") or "") + " " +
            "Investiga de forma coordinada el tema común «" + topic +
            "» y las tendencias relacionadas: " + ", ".join(names) +
            ". Conserva todos los identificadores y revisiones; evita conclusiones " +
            "duplicadas y agrupa solo hechos realmente vinculados."
        )
    for entry in queue.get("items", []):
        if entry.get("id") not in ids:
            continue
        canonical = next(row for row in matching if row["id"] == entry["id"])
        for field in ("requested_together", "group_topic", "group_request_id",
                      "group_members", "rewrite_instruction"):
            entry[field] = canonical[field]
    req["updated_at"] = queue["updated_at"] = stamp
    save(req_path, req)
    save(queue_path, queue)
    return identity


def main():
    request_id, project, decision, items, topic = validate(
        json.loads(os.environ["TT_ACTUALIDAD_BATCH_JSON"]))
    ledger = load(RECEIPTS, {"version": 1, "items": []})
    if any(row.get("request_id") == request_id for row in ledger.get("items", [])):
        print("TT_ACTUALIDAD_BATCH_ALREADY_APPLIED", request_id)
        return
    existing = []
    if project == "ttendencias" and decision == "rework":
        existing = [row.get("id") for row in load("trends/requests.json", {"requests": []}).get("requests", [])]

    results = []
    for item in items:
        changes, status = apply_live(
            project, item["event_id"], decision, item["revision"],
            item["title"].strip(), item.get("rank", 0))
        for location, document in changes.items():
            save(location, document)
        results.append({"event_id": item["event_id"],
                        "revision": item["revision"], "status": status})
    stamp = datetime.now(timezone.utc).isoformat()
    group_members = []
    if decision == "rework":
        group_members = group_requests(request_id, items, topic, existing, stamp)
    ledger.setdefault("items", []).append({
        "request_id": request_id, "project": project, "decision": decision,
        "status": "applied", "items": results, "group_members": group_members,
        "group_topic": topic, "at": stamp,
    })
    ledger["items"] = ledger["items"][-500:]
    save(RECEIPTS, ledger)
    print("TT_ACTUALIDAD_BATCH_APPLIED", request_id, len(items), decision)


if __name__ == "__main__":
    main()
