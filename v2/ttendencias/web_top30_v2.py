#!/usr/bin/env python3
"""TTActualidad V2: exportar Top30 público (solo lectura, sin credenciales).

El snapshot procede de una pareja historial/cola V2 del mismo instante.
No expone tokens, leases, prompts, ID de sesión ni cola de producción.
"""
import argparse
import base64
import importlib.util
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import time
from datetime import datetime, timezone

BRANCH = "feature/ttactualidad-v2-clean"
REPO = "fabricelop/europapress-rss"
DIR = "v2/ttendencias/state"
API = "https://api.github.com/repos/" + REPO + "/contents/"
ROOT = pathlib.Path(__file__).resolve().parents[2]
STATE = ROOT / DIR
STATUS = {
    "pending": ("pendiente", "Pendiente"),
    "review_pending": ("pendiente", "Pendiente"),
    "in_progress": ("en_elaboracion", "En elaboración"),
    "capture_recovery": ("incidencia", "Incidencia"),
    "captured_review": ("explicada", "Explicada · por revisar"),
    "ready": ("explicada", "Explicada"),
    "published": ("explicada", "Explicada"),
    "dismissed": ("desestimada", "Desestimada"),
    "cancelled": ("incidencia", "Incidencia"),
}


def cause_status(answer):
    match = re.search(r"(?im)^\s*ESTADO_CAUSA\s*:\s*(CONFIRMADA|NO_CONFIRMADA)\s*$", answer)
    if match:
        return "confirmada_declarada" if match.group(1).upper() == "CONFIRMADA" else "no_confirmada"
    patterns = ("motivo no confirmado", "motivo no verificado", "no se ha podido confirmar")
    return "no_confirmada" if any(p in answer.lower() for p in patterns) else "sin_clasificar"


def saved_image_for_revision(item):
    """Solo indicar una imagen que el endpoint privado pueda servir íntegra."""
    cap = item.get("capture") or {}
    image = cap.get("image") or {}
    rev = item.get("revision")
    ident = item.get("trend_id") or ""
    sha = image.get("sha256") or ""
    ext = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}.get(image.get("mime"))
    expected = (f"v2/ttendencias/generated-images/{ident}-r{rev}-{sha[:24]}.{ext}"
                if ext else None)
    return (item.get("status") in ("captured_review", "ready", "published")
            and isinstance(rev, int) and rev > 0
            and cap.get("revision") == rev
            and image.get("status") == "saved"
            and image.get("revision") == rev
            and image.get("backend") == "github_v1_style"
            and bool(re.fullmatch(r"trv2-[a-f0-9]{24}", ident))
            and bool(re.fullmatch(r"[a-f0-9]{64}", sha))
            and bool(re.fullmatch(r"v2-img-trv2-[a-f0-9]{24}-r[1-9][0-9]*-a[1-9][0-9]*-[a-zA-Z0-9_-]{8,60}",
                                  image.get("command_id") or ""))
            and image.get("path") == expected)


def build(history, queue):
    if (history.get("step") != "03_movement" or history.get("country") != "ES"
        or queue.get("step") != "04_editorial_queue"
        or queue.get("effects_enabled") is not False
        or queue.get("source_observed_at") != history.get("observed_at")):
        raise ValueError("Historial y cola V2 no corresponden a la misma captura")
    names = history.get("top30")
    if not isinstance(names, list) or len(names) != 30 or len(set(names)) != 30:
        raise ValueError("Top30 incompleto o inconsistente")
    by_rank = {}
    for topic in (history.get("topics") or {}).values():
        if topic.get("active") is not True:
            continue
        rank = topic.get("rank")
        if not isinstance(rank, int) or not 1 <= rank <= 30:
            continue
        if rank in by_rank or topic.get("name") != names[rank - 1]:
            raise ValueError("Ranking duplicado o incoherente")
        by_rank[rank] = topic
    if len(by_rank) != 30:
        raise ValueError("Ranking incompleto")
    result = []
    for rank in range(1, 31):
        topic = by_rank[rank]
        item = (queue.get("items") or {}).get(topic["trend_id"]) or {}
        tech = item.get("status") or "pending"
        if tech not in STATUS:
            raise ValueError("Estado editorial desconocido: " + str(tech))
        category, label = STATUS[tech]
        if tech == "in_progress":
            # El lease caducado es incidencia, NO una autorización de reenvío.
            raw_expiry = (item.get("lease") or {}).get("expires_at")
            try:
                if raw_expiry:
                    expiry = datetime.fromisoformat(raw_expiry.replace("Z", "+00:00"))
                    if expiry.tzinfo is not None and expiry < datetime.now(timezone.utc):
                        category, label = "incidencia", "Elaboración interrumpida"
            except (ValueError, TypeError):
                category, label = "incidencia", "Reserva no válida"
        answer = ""
        chat_url = ""
        captured_at = ""
        displayed_revision = item.get("revision") or 1
        image_available = saved_image_for_revision(item)
        re_in_progress = (item.get("reason") == "user_reexplanation"
                          and tech in ("review_pending", "in_progress", "capture_recovery"))
        if tech == "captured_review":
            capture = item.get("capture") or {}
            if (capture.get("verified_complete") is True
                and capture.get("revision") == item.get("revision")
                and isinstance(capture.get("answer"), str)
                and len(capture["answer"].strip()) >= 80
                and isinstance(capture.get("sha256"), str)
                and len(capture["sha256"]) == 64):
                answer = capture["answer"].strip()
                candidate = capture.get("chat_url") or ""
                if isinstance(candidate, str) and candidate.startswith("https://chatgpt.com/c/"):
                    chat_url = candidate
                captured_at = capture.get("captured_at") or ""
            else:
                category, label = "incidencia", "Incidencia de captura"
        elif tech in ("ready", "published"):
            answer = item.get("text") if isinstance(item.get("text"), str) else ""
            if not answer.strip():
                category, label = "incidencia", "Sin texto confirmado"
            captured_at = item.get("completed_at") or ""
        elif re_in_progress:
            # Un RE aceptado comienza una ficha limpia en la nueva revisión.
            # Nunca proyectar texto/imagen de una revisión anterior.
            category, label = ("en_elaboracion", "En revisión · nueva explicación") if tech == "in_progress" else ("pendiente", "En revisión · reinicio editorial")
            image_available = False
        result.append({
            "rank": rank,
            "name": topic["name"],
            "entered_top30_at": topic.get("entered_top30_at") or topic.get("first_seen_at") or "",
            "trend_id": topic["trend_id"],
            "revision": displayed_revision,
            "status": category,
            "status_label": label,
            "editorial_status": tech,
            "re_in_progress": re_in_progress,
            "pending_editorial_review": tech == "captured_review",
            "explanation": answer,
            "cause_status": cause_status(answer) if answer else "sin_datos",
            "chat_url": chat_url,
            "captured_at": captured_at,
            "image_available": image_available,
            "movement": topic.get("last_change") or "",
            "previous_rank": topic.get("previous_rank") if isinstance(topic.get("previous_rank"), int) else None,
            "positions_changed": topic.get("positions_changed") if isinstance(topic.get("positions_changed"), int) else None,
        })
    return {
        "schema_version": 1,
        "project": "ttactualidad-v2",
        "country": "ES",
        "source": history.get("source") or "GetDayTrends",
        "captured_at": history["observed_at"],
        "comparison_at": history.get("previous_observed_at"),
        # Hora de consulta y hora de último cambio REAL son conceptos distintos.
        "ranking_unchanged": history.get("ranking_unchanged") is True,
        "ranking_change_at": history.get("ranking_change_at"),
        "source_verified_against_x": False,
        "publication_allowed": False,
        "count": 30,
        "items": result,
    }


def gh(method, auth, path, payload=None):
    url = API + DIR + "/" + path
    if method == "GET":
        url += "?ref=" + urllib.parse.quote(BRANCH, safe="")
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Accept": "application/vnd.github+json",
               "Authorization": "Bearer " + auth,
               "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "TTActualidadV2-WebTop30"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, headers=headers, data=body, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 404 and method == "GET":
            return None
        raise RuntimeError("GitHub Top30 web HTTP %d" % exc.code) from None


def read_remote(auth, name):
    response = gh("GET", auth, name)
    if response is None:
        raise RuntimeError("Falta estado V2: " + name)
    return json.loads(base64.b64decode(response["content"])), response["sha"]


def sync_to_github(auth):
    """Solo sincronizar la proyección V2, con tolerancia a refresco concurrente.

    Si cambian los SHA de historial/cola por el cron, recomputar en vez de
    publicar un snapshot de fechas mezcladas. Nunca toca V1 ni publica.
    """
    last_error = ""
    for attempt in range(4):
        try:
            history, _ = read_remote(auth, "history.json")
            queue, _ = read_remote(auth, "editorial-queue.json")
            expected = build(history, queue)
            current = gh("GET", auth, "web-top30.json")
            stored = json.loads(base64.b64decode(current["content"])) if current else None
            if stored != expected:
                payload = {
                    "branch": BRANCH,
                    "message": "v2: refresh live Top30 web preview",
                    "content": base64.b64encode((json.dumps(expected, ensure_ascii=False,
                                                           indent=2) + "\n").encode("utf-8")).decode("ascii"),
                }
                if current:
                    payload["sha"] = current["sha"]
                result = gh("PUT", auth, "web-top30.json", payload)
                if not (result or {}).get("commit", {}).get("sha"):
                    raise RuntimeError("GitHub no confirmó Top30 web")
            verified, _ = read_remote(auth, "web-top30.json")
            if verified != expected:
                raise RuntimeError("Top30 web modificado concurrentemente")
            return expected
        except (RuntimeError, ValueError) as exc:
            last_error = str(exc)
            if attempt == 3:
                raise RuntimeError("Top30 web no sincronizado: " + last_error) from exc
            time.sleep(1 + attempt)
    raise RuntimeError("Top30 web no sincronizado: " + last_error)

def local_json(path):
    target = pathlib.Path(path).resolve()
    if target.parent != STATE.resolve() or target.suffix != ".json":
        raise ValueError("Solo v2/ttendencias/state/*.json")
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--history")
    parser.add_argument("--queue")
    parser.add_argument("--output")
    parser.add_argument("--sync", action="store_true")
    args = parser.parse_args()
    if args.sync:
        # Solo el flujo editorial V2 autorizado invoca sync.
        from persist_capture_github import token
        projected = sync_to_github(token())
        print("TT_V2_WEB_TOP30_SYNCED=YES")
    else:
        if not args.history or not args.queue or not args.output:
            parser.error("Se requieren --history, --queue y --output")
        projected = build(
            json.loads(local_json(args.history).read_text(encoding="utf-8")),
            json.loads(local_json(args.queue).read_text(encoding="utf-8")))
        local_json(args.output).write_text(
            json.dumps(projected, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8")
        print("TT_V2_WEB_TOP30_LOCAL_READY=YES")
    print("TT_V2_WEB_TOP30_COUNT=" + str(projected["count"]))
    print("TT_V2_PUBLISHED=NO")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_WEB_TOP30_ERROR=" + str(exc), file=sys.stderr)
        sys.exit(1)
