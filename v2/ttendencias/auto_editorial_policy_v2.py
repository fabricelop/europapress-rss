#!/usr/bin/env python3
"""Selección pura para el consumidor automático TTActualidad V2."""
import pathlib
from select_current_top30_v2 import select_current_top30


def eligible_plan(queue, history, *, directory, now=None):
    """Puesto 1→30. Un diario local previo impide reenvío accidental."""
    ranked, age = select_current_top30(queue, history, 30, now=now)
    blocked = []
    for item in ranked:
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
