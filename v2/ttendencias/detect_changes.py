#!/usr/bin/env python3
"""Paso 3: seguimiento determinista del Top30 de TTActualidad V2.

Sin acceso a la cola editorial, sin API y sin escrituras a producción.
Una ausencia observada y un regreso son distintos de un cambio de posición.
"""
import argparse
import hashlib
import json
from datetime import timedelta
from pathlib import Path

from trends.update_trends import term_key
from v2.ttendencias.assess_freshness import evaluate, moment

ROOT = Path(__file__).resolve().parents[2]
STATE_DIR = (ROOT / "v2/ttendencias/state").resolve()
MIN_REEXPLAIN_ABSENCE = timedelta(hours=24)  # estrictamente más de 24 h fuera


def stable_trend_id(key):
    """La identidad nunca incorpora fecha, posición ni número de episodio."""
    return "trv2-" + hashlib.sha256(("ES|" + key).encode()).hexdigest()[:24]


def episode_id(key, entered_at):
    return hashlib.sha256(f"{key}|{entered_at}".encode()).hexdigest()[:16]


def build(snapshot, previous=None, *, now=None):
    check = evaluate(snapshot, now=now)
    if not check["eligible_for_editorial"]:
        raise ValueError("Captura no válida/vencida: no alterar el historial V2")
    at = moment(snapshot["observed_at"])
    stamp = at.isoformat()
    rows = dict((previous or {}).get("topics") or {})
    previous_at = (previous or {}).get("observed_at")
    if previous:
        if (previous.get("schema_version") != 1 or previous.get("step") != "03_movement"
                or previous.get("country") != "ES" or not previous_at):
            raise ValueError("Estado V2 anterior incompatible")
        prior = moment(previous_at)
        if at < prior:
            raise ValueError("Captura antigua: no sobrescribir estado posterior")
        if at == prior:
            # Mismo instante y mismo ranking: idempotente; si difiere, no mezclar.
            if list(snapshot["top30"]) != list(previous.get("top30") or []):
                raise ValueError("Capturas contradictorias para la misma fecha")
            return {"state": previous, "changes": [], "idempotent": True}

    fresh = {}
    changes = []
    initial = previous is None
    for rank, name in enumerate(snapshot["top30"], 1):
        key = term_key(name)
        old = dict(rows.get(key) or {})
        prior_rank = old.get("rank") if old.get("active") else None
        status = "unchanged"
        if not old:
            # Primera captura crea la línea base, no 30 novedades artificiales.
            status = "baseline" if initial else "entry"
            entered = stamp
            old = {"trend_id": stable_trend_id(key), "first_seen_at": stamp, "episode_number": 1,
                   "episode_token": episode_id(key, entered),
                   "entered_top30_at": entered}
        elif not old.get("active"):
            exited = moment(old["exited_at"])
            absence = at - exited
            if absence > MIN_REEXPLAIN_ABSENCE:
                status = "reentry"
                old["episode_number"] = int(old.get("episode_number") or 1) + 1
                old["entered_top30_at"] = stamp
                old["episode_token"] = episode_id(key, stamp)
            else:
                status = "short_return"  # Hasta 24 h fuera: no proponer nueva explicación
                old["entered_top30_at"] = stamp  # Nuevo tramo de presencia, SIN revisar el episodio
        elif prior_rank != rank:
            status = "up" if rank < prior_rank else "down"
        old.update(name=name, key=key, trend_id=stable_trend_id(key), active=True, rank=rank, last_seen_at=stamp,
                   exited_at=None, last_change=status)
        fresh[key] = old
        if status in {"entry", "reentry", "up", "down", "short_return"}:
            changes.append({"kind": status, "key": key, "name": name,
                            "rank": rank, "previous_rank": prior_rank,
                            "trend_id": old["trend_id"],
                            "episode_token": old["episode_token"],
                            "reexplain_candidate": status == "reentry",
                            "at": stamp})
    for key, old in rows.items():
        if key in fresh:
            continue
        old = dict(old)
        if old.get("active"):
            old.update(active=False, rank=None, exited_at=stamp, last_change="exit")
            changes.append({"kind": "exit", "key": key, "name": old["name"],
                            "rank": None, "previous_rank": rows[key].get("rank"),
                            "trend_id": old.get("trend_id") or stable_trend_id(key),
                            "episode_token": old["episode_token"], "at": stamp})
        # No se podan identidades: regresar meses después conserva el mismo trend_id.
        # El historial es exclusivamente V2 y se almacenará separado del flujo actual.
        fresh[key] = old
    state = {"schema_version": 1, "step": "03_movement", "country": "ES",
             "source": snapshot["source"], "observed_at": stamp,
             "top30": list(snapshot["top30"]), "topics": fresh,
             "change_count": len(changes), "bootstrap": initial}
    return {"state": state, "changes": changes, "idempotent": False}


def local_json(path):
    p = Path(path).resolve()
    if p.parent != STATE_DIR or p.suffix != ".json":
        raise ValueError("Las entradas/salidas de estado se restringen a v2/ttendencias/state/*.json")
    return p


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", help="Snapshot JSON V2 del paso 1")
    parser.add_argument("--previous", help="Historial del paso 3, opcional")
    parser.add_argument("--output", help="Guardar estado SOLO dentro de v2/ttendencias/state/")
    args = parser.parse_args()
    snapshot = json.loads(local_json(args.capture).read_text(encoding="utf-8"))
    previous = json.loads(local_json(args.previous).read_text(encoding="utf-8")) if args.previous else None
    result = build(snapshot, previous)
    if args.output:
        target = local_json(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(result["state"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"step": "03_movement", "captured_at": result["state"]["observed_at"],
                      "count": len(result["state"]["top30"]), "bootstrap": result["state"]["bootstrap"],
                      "idempotent": result["idempotent"], "changes": result["changes"]},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
