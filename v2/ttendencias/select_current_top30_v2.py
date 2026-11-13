#!/usr/bin/env python3
"""Selección del Top30 ACTUAL de V2, nunca vaciado accidental del backlog.

Lee historial y cola de la misma rama. Fuente única GetDayTrends, NO prueba
de frescura intrínseca de X. Si falta una captura reciente, aborta sin envío.
"""
import base64
import json
import urllib.parse
import urllib.request
from datetime import datetime, timezone

BRANCH = "feature/ttactualidad-v2-clean"
URL = ("https://api.github.com/repos/fabricelop/europapress-rss/contents/"
       "v2/ttendencias/state/history.json")
OPEN = {"pending", "review_pending"}


def read_history(auth):
    endpoint = URL + "?ref=" + urllib.parse.quote(BRANCH, safe="")
    headers = {
        "Authorization": "Bearer " + auth,
        "Accept": "application/vnd.github+json",
        "User-Agent": "TTActualidadV2-current-top30",
    }
    request = urllib.request.Request(endpoint, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
    return json.loads(base64.b64decode(data["content"]).decode("utf-8"))


def select_current_top30(queue, history, limit, *, now=None, max_age_minutes=20):
    """Devuelve trabajos no enviados en orden del puesto 1 al 30.

    Rechaza fuentes desactualizadas o inconsistentes y jamás recurre
    silenciosamente a tendencias históricas. El backlog permanece guardado.
    """
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 30:
        raise ValueError("Consulta de ranking: límite entre 1 y 30; tanda limitada por su CLI")
    if queue.get("step") != "04_editorial_queue" or queue.get("effects_enabled") is not False:
        raise ValueError("Cola V2 inválida")
    if history.get("step") != "03_movement" or history.get("country") != "ES":
        raise ValueError("Historial V2 inválido")
    if queue.get("source_observed_at") != history.get("observed_at"):
        raise ValueError("Top30 y cola son de capturas diferentes: no enviar")
    stamp = history.get("observed_at")
    if not isinstance(stamp, str):
        raise ValueError("Captura sin fecha")
    observed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    if observed.tzinfo is None:
        raise ValueError("Captura sin zona horaria")
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("Reloj sin zona horaria")
    age = (now - observed).total_seconds() / 60
    if age < -2 or age > max_age_minutes:
        raise ValueError("Top30 no actualizado (edad %.1f min): no enviar" % age)
    names = history.get("top30") or []
    topics = history.get("topics") or {}
    if len(names) != 30 or not isinstance(topics, dict):
        raise ValueError("Top30 incompleto")
    ranked = {}
    for topic in topics.values():
        if topic.get("active") is not True:
            continue
        rank = topic.get("rank")
        if not isinstance(rank, int) or not 1 <= rank <= 30:
            continue
        if rank in ranked:
            raise ValueError("Puesto duplicado en historial V2")
        if topic.get("name") != names[rank - 1]:
            raise ValueError("Top30 y detalle histórico no coinciden")
        ranked[rank] = topic["trend_id"]
    if len(ranked) != 30 or len(set(ranked.values())) != 30:
        raise ValueError("Top30 no consistente")
    results = []
    for rank in range(1, 31):
        item = queue.get("items", {}).get(ranked[rank])
        if not item or item.get("status") not in OPEN:
            continue
        if item.get("send_intent") or item.get("lease") or item.get("capture"):
            continue
        if int(item.get("attempts", 0)) >= 3:
            continue
        results.append(item)
        if len(results) >= limit:
            break
    return results, round(age, 2)
