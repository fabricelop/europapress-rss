#!/usr/bin/env python3
"""Paso 5A V2: reservas editoriales puras, SIN invocar ChatGPT.

Un trabajo pasa a in_progress únicamente si un consumidor concreto lo reclama.
La reserva tiene token, revisión, vencimiento y reintentos acotados. Una
respuesta vieja no puede cerrar una revisión nueva. No se escribe producción.
"""
import copy
import hashlib
import json
from datetime import datetime, timedelta, timezone

from v2.ttendencias.assess_freshness import moment

LEASE_MINUTES = 15
MAX_ATTEMPTS = 3
OPEN = {"pending", "review_pending"}
FINISHED = {"ready", "published", "dismissed", "cancelled"}
# captured_review se cuenta como pendiente pero NO se vuelve a enviar a ChatGPT.


def _now(value=None):
    t = value or datetime.now(timezone.utc)
    if t.tzinfo is None:
        raise ValueError("Se requiere hora con zona")
    return t.astimezone(timezone.utc)


def _check(queue):
    if queue.get("step") != "04_editorial_queue" or queue.get("country") != "ES":
        raise ValueError("La cola no pertenece a TTendencias V2")
    if queue.get("effects_enabled") is not False:
        raise ValueError("Las llamadas externas deben seguir deshabilitadas")
    if not isinstance(queue.get("items"), dict):
        raise ValueError("Cola inválida")


def _refresh(q):
    active = sorted(
        (item for item in q["items"].values()
         if item["status"] in {"pending", "review_pending", "in_progress", "captured_review"}),
        key=lambda x: (x.get("requested_at", ""), x["trend_id"]),
    )
    q["pending_count"] = len(active)
    q["pending_ids"] = [item["trend_id"] for item in active]
    return q


def recover(queue, *, now=None):
    """Reabrir reservas vencidas; detener tras MAX_ATTEMPTS sin perder ficha."""
    _check(queue)
    t = _now(now)
    q = copy.deepcopy(queue)
    events = []
    for item in q["items"].values():
        if item.get("status") != "in_progress":
            continue
        lease = item.get("lease")
        if not isinstance(lease, dict) or not lease.get("expires_at"):
            raise ValueError("in_progress sin reserva válida")
        if moment(lease["expires_at"]) > t:
            continue
        attempts = int(item.get("attempts", 0))
        item["status"] = "review_pending" if item.get("revision", 1) > 1 else "pending"
        if attempts >= MAX_ATTEMPTS:
            item["status"] = "cancelled"
            item["failure_reason"] = "max_attempts_exceeded"
        item.pop("lease", None)
        item["updated_at"] = t.isoformat()
        events.append({"action": "lease_expired", "trend_id": item["trend_id"],
                       "revision": item["revision"], "status": item["status"]})
    return _refresh(q), events


def claim(queue, *, worker_id, now=None, capacity=1):
    """Reserva hasta capacity elementos; nunca crea trabajo ficticio."""
    if not worker_id or len(worker_id) > 128:
        raise ValueError("Identificador de consumidor inválido")
    if not isinstance(capacity, int) or capacity < 1 or capacity > 10:
        raise ValueError("Capacidad fuera de rango")
    t = _now(now)
    q, events = recover(queue, now=t)
    running = sum(x["status"] == "in_progress" for x in q["items"].values())
    available = max(0, capacity - running)
    candidates = sorted((x for x in q["items"].values() if x["status"] in OPEN),
                        key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
    jobs = []
    for item in candidates[:available]:
        attempt = int(item.get("attempts", 0)) + 1
        if attempt > MAX_ATTEMPTS:
            item["status"] = "cancelled"
            item["failure_reason"] = "max_attempts_exceeded"
            continue
        token = hashlib.sha256(
            f'{item["trend_id"]}|{item["revision"]}|{attempt}|{worker_id}|{t.isoformat()}'.encode()
        ).hexdigest()
        item["status"] = "in_progress"
        item["attempts"] = attempt
        item["lease"] = {"token": token, "worker_id": worker_id,
                         "started_at": t.isoformat(),
                         "expires_at": (t + timedelta(minutes=LEASE_MINUTES)).isoformat()}
        item["updated_at"] = t.isoformat()
        jobs.append({"trend_id": item["trend_id"], "name": item["name"],
                     "revision": item["revision"], "token": token,
                     "worker_id": worker_id, "expires_at": item["lease"]["expires_at"]})
    return _refresh(q), jobs, events


def complete(queue, *, trend_id, revision, token, text, now=None):
    """Cerrar únicamente la reserva vigente, con texto editorial no vacío."""
    _check(queue)
    t = _now(now)
    if not isinstance(text, str) or not text.strip():
        raise ValueError("No se acepta una explicación vacía")
    q = copy.deepcopy(queue)
    item = q["items"].get(trend_id)
    if not item or item["status"] != "in_progress" or item["revision"] != revision:
        raise ValueError("Trabajo inexistente, cerrado o revisión obsoleta")
    lease = item.get("lease") or {}
    if lease.get("token") != token or moment(lease["expires_at"]) <= t:
        raise ValueError("Reserva no vigente")
    item["status"] = "ready"
    item["text"] = text.strip()
    item["completed_at"] = t.isoformat()
    item["updated_at"] = t.isoformat()
    item.pop("lease", None)
    return _refresh(q)


def main():
    """Demostración solo lectura; nunca persiste cambios ni reclama en GitHub."""
    import argparse
    from pathlib import Path
    from v2.ttendencias.detect_changes import local_json
    parser = argparse.ArgumentParser()
    parser.add_argument("queue")
    parser.add_argument("--simulate-worker", default="v2-dry-run")
    args = parser.parse_args()
    data = json.loads(local_json(args.queue).read_text(encoding="utf-8"))
    _, jobs, _ = claim(data, worker_id=args.simulate_worker, capacity=1)
    print(json.dumps({"mode": "simulation_only", "saved": False,
                      "chatgpt_called": False, "jobs": jobs}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
