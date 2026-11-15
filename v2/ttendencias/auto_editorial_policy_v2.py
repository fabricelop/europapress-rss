#!/usr/bin/env python3
"""Selección pura para el consumidor automático TTActualidad V2."""
import pathlib
from datetime import datetime, timezone
from select_current_top30_v2 import select_current_top30


def eligible_plan(queue, history, *, directory, now=None, active_keys=()):
    """RE explícitos primero; después Top30 1→30, sin duplicar envíos."""
    now = now or datetime.now(timezone.utc)
    if (queue.get("step") != "04_editorial_queue"
            or queue.get("effects_enabled") is not False
            or history.get("step") != "03_movement"
            or history.get("country") != "ES"
            or queue.get("source_observed_at") != history.get("observed_at")):
        raise ValueError("Cola e historial V2 no corresponden")
    observed = datetime.fromisoformat(history["observed_at"].replace("Z", "+00:00"))
    if observed.tzinfo is None or now.tzinfo is None:
        raise ValueError("Fecha editorial sin zona horaria")
    age = round((now - observed).total_seconds() / 60, 2)
    known_ids = {topic.get("trend_id") for topic in history.get("topics", {}).values()}
    reviews = sorted((item for item in queue.get("items", {}).values()
                      if item.get("status") == "review_pending"
                      and item.get("reason") == "user_reexplanation"
                      and item.get("trend_id") in known_ids
                      and isinstance(item.get("revision"), int) and item["revision"] >= 2
                      and not any(item.get(field) for field in ("send_intent", "lease", "capture"))
                      and int(item.get("attempts", 0)) < 3),
                     key=lambda item: (item.get("requested_at", ""), item["trend_id"]))
    blocked = []
    active = set(active_keys)
    for item in reviews:
        if (item["trend_id"], item["revision"]) in active:
            continue
        journal = pathlib.Path(directory) / (
            "run-" + item["trend_id"] + "-r" + str(item["revision"]) + ".json")
        if journal.exists():
            blocked.append(item["trend_id"])
            continue
        return item, age, blocked
    # An old ranking still blocks *new* automatic topics; explicit RE is
    # independent of the radar freshness once its identity is verified.
    ranked, age = select_current_top30(queue, history, 30, now=now)
    for item in ranked:
        if (item["trend_id"], item["revision"]) in active:
            continue
        journal = pathlib.Path(directory) / (
            "run-" + item["trend_id"] + "-r" + str(item["revision"]) + ".json")
        if journal.exists():
            blocked.append(item["trend_id"])
            continue
        return item, age, blocked
    return None, age, blocked


def enabled_text(contents):
    """Solo la marca exacta habilita sesiones automáticas con ChatGPT."""
    return str(contents).lstrip("\ufeff").strip() == "TT_V2_AUTO_EDITORIAL_ENABLED=YES"
