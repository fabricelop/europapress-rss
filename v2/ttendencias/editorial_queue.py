#!/usr/bin/env python3
"""Paso 4: cola editorial V2, determinista y sin ejecución de ChatGPT.

Identidad = trend_id estable. Revisión = número que solo aumenta cuando un
regreso >24 horas o una decisión editorial explícita requiere nueva revisión.
No importa ni escribe NINGUNA cola de producción.
"""
import argparse
import json
from pathlib import Path

from v2.ttendencias.detect_changes import local_json

ACTIVE = {"pending", "review_pending", "in_progress"}
CLOSED = {"ready", "published", "dismissed", "cancelled"}
VALID = ACTIVE | CLOSED


def sync_queue(history, previous=None, *, changed_explanations=None):
    if history.get("step") != "03_movement" or history.get("country") != "ES":
        raise ValueError("Se requiere historial validado del paso 3")
    captured = history.get("observed_at")
    topics = history.get("topics") or {}
    top30 = history.get("top30") or []
    if len(top30) != 30:
        raise ValueError("Top30 incompleto")
    original = previous or {}
    if previous and (previous.get("step") != "04_editorial_queue" or previous.get("country") != "ES"):
        raise ValueError("Cola anterior incompatible")
    if previous and str(original.get("source_observed_at") or "") > str(captured):
        raise ValueError("No se puede retroceder la cola editorial")
    existing = original.get("items") or {}
    if not isinstance(existing, dict):
        raise ValueError("items de cola debe ser un diccionario por trend_id")
    changed = set(changed_explanations or ())
    valid_ids = {row.get("trend_id") for row in topics.values()}
    if changed - valid_ids:
        raise ValueError("No se admite un cambio editorial de ID desconocido")
    by_key = {}
    for key, trend in topics.items():
        tid = trend.get("trend_id")
        if not tid or tid in by_key:
            raise ValueError("Historial con ID de tendencia vacío o duplicado")
        by_key[tid] = trend
    if not set(existing).issubset(by_key):
        raise ValueError("La cola contiene IDs no presentes en el historial persistido")
    result = {key: dict(item) for key, item in existing.items()}
    changes = []
    for tid, trend in by_key.items():
        if not trend.get("active"):
            continue
        prev = result.get(tid)
        if prev is None:
            item = {"trend_id": tid, "name": trend["name"], "revision": 1,
                    "status": "pending", "reason": "first_explanation",
                    "episode_token": trend["episode_token"],
                    "requested_at": captured, "updated_at": captured,
                    "previous_explanation": None}
            result[tid] = item
            changes.append({"action": "enqueue", "trend_id": tid, "revision": 1})
            continue
        if prev.get("status") not in VALID or int(prev.get("revision", 0)) < 1:
            raise ValueError("Cola previa corrupta o estado desconocido")
        item = dict(prev)
        item["name"] = trend["name"]
        # Los movimientos de ranking, como las relecturas, no generan revisiones.
        new_episode = item.get("episode_token") != trend.get("episode_token")
        explicit_change = tid in changed
        if (new_episode or explicit_change) and item["status"] in CLOSED:
            item["previous_explanation"] = {
                "revision": item["revision"], "status": item["status"],
                "completed_at": item.get("completed_at"),
                "text": item.get("text"),
            }
            item["revision"] = int(item["revision"]) + 1
            item["status"] = "review_pending"
            item["reason"] = "changed_explanation" if explicit_change else "return_after_24h"
            item["requested_at"] = captured
            item["updated_at"] = captured
            item["episode_token"] = trend["episode_token"]
            item.pop("completed_at", None)
            item.pop("text", None)
            changes.append({"action": "review", "trend_id": tid, "revision": item["revision"], "reason": item["reason"]})
        elif new_episode and item["status"] in ACTIVE:
            # Nunca duplicar un trabajo pendiente o iniciado por reentrada.
            item["episode_token"] = trend["episode_token"]
        result[tid] = item
    pending = sorted((x for x in result.values() if x["status"] in ACTIVE),
                     key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
    state = {"schema_version": 1, "step": "04_editorial_queue", "country": "ES",
             "source_observed_at": captured, "items": result,
             "pending_count": len(pending),
             "pending_ids": [row["trend_id"] for row in pending],
             "effects_enabled": False}
    return {"state": state, "changes": changes}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("history")
    parser.add_argument("--previous")
    parser.add_argument("--output", help="Solo bajo v2/ttendencias/state/")
    args = parser.parse_args()
    hist = json.loads(local_json(args.history).read_text(encoding="utf-8"))
    old = json.loads(local_json(args.previous).read_text(encoding="utf-8")) if args.previous else None
    result = sync_queue(hist, old)
    if args.output:
        file = local_json(args.output)
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(result["state"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"step": "04_editorial_queue", "pending": result["state"]["pending_count"],
                      "new_requests": result["changes"], "effects_enabled": False},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
