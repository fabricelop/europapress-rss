#!/usr/bin/env python3
"""Proyección aislada de fichas V2 para Listas, incluso con causa dudosa.

La cola V2 sigue siendo autoritativa: Listas no implica READY, aprobación
editorial, publicación ni escritura en main. No hay dependencia de V1.
"""
import argparse
import base64
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

BRANCH = "feature/ttactualidad-v2-clean"
API = "https://api.github.com/repos/fabricelop/europapress-rss/contents/v2/ttendencias/state/listas.json"
VISIBLE = {"captured_review", "ready"}
UNCERTAIN_PATTERNS = (
    r"\bmotivo\s+no\s+verificad[oa]\b",
    r"\bmotivo\s+no\s+confirmad[oa]\b",
    r"\bno\s+se\s+ha\s+podido\s+(?:verificar|confirmar|identificar)\b",
    r"\bno\s+hay\s+pruebas\s+suficientes\b",
    r"\bresultado\s+editorial:\s*no\s+verificado\b",
    r"\bno\s+se\s+puede\s+identificar\s+con\s+seguridad\b",
)
POST_URL = re.compile(r"https://(?:www\.)?x\.com/[A-Za-z0-9_]{1,15}/status/\d+\b")


def classify_cause(answer):
    """Afirmaciones del borrador, NO verificación independiente."""
    found = re.search(r"(?im)^\s*ESTADO_CAUSA\s*:\s*(CONFIRMADA|NO_CONFIRMADA)\s*$", answer)
    if found:
        return "no_confirmada" if found.group(1).upper() == "NO_CONFIRMADA" else "declarada_confirmada"
    if any(re.search(pattern, answer, re.I) for pattern in UNCERTAIN_PATTERNS):
        return "no_confirmada"
    # No interpretar la ausencia de cautelas como certeza.
    return "sin_clasificar"


def classify_x(answer):
    match = re.search(r"(?im)^\s*ESTADO_X\s*:\s*(CONSULTADO|INACCESIBLE|NO_NECESARIO)\s*$", answer)
    links = sorted(set(POST_URL.findall(answer)))
    if not match:
        return "no_documentado", links
    state = match.group(1).upper()
    if state == "CONSULTADO":
        # Los enlaces son evidencia de atribución del modelo, NO de
        # navegación independiente observada por el consumidor.
        return ("declarado_con_enlaces" if links else "declarado_sin_enlaces"), links
    return {"INACCESIBLE": "inaccesible", "NO_NECESARIO": "no_necesario"}[state], links


def build_listas(queue, queue_sha):
    if queue.get("step") != "04_editorial_queue" or queue.get("effects_enabled") is not False:
        raise ValueError("Cola V2 incorrecta o con efectos activos")
    if not isinstance(queue.get("items"), dict) or not queue_sha:
        raise ValueError("Sin identificador de versión de la cola")
    items = {}
    for trend_id, item in sorted(queue["items"].items()):
        if item.get("status") not in VISIBLE:
            continue
        cap = item.get("capture") or {}
        answer = cap.get("answer") or item.get("text") or ""
        digest = cap.get("sha256")
        if (not isinstance(answer, str) or len(answer.strip()) < 80
            or not isinstance(digest, str) or len(digest) != 64
            or cap.get("revision") != item.get("revision")):
            # No mostrar nunca como ficha una respuesta parcial o errónea.
            continue
        if item.get("status") == "captured_review" and cap.get("verified_complete") is not True:
            continue
        cause = classify_cause(answer)
        x_status, x_posts = classify_x(answer)
        items[trend_id] = {
            "trend_id": trend_id,
            "revision": item["revision"],
            "name": item.get("name", ""),
            "editorial_status": item["status"],
            "listas_status": "pendiente_revision" if item["status"] == "captured_review" else "revisada",
            "cause_status": cause,
            "uncertain_cause": cause == "no_confirmada",
            "label": ("Motivo no confirmado" if cause == "no_confirmada"
                      else ("Causa por revisar" if item["status"] != "ready"
                            else "Revisión editorial completada")),
            "x_status": x_status,
            "x_post_urls": x_posts,
            "text": answer.strip(),
            "capture_sha256": digest,
            "chat_url": cap.get("chat_url"),
            "editorial_validated": item["status"] == "ready" and bool(item.get("validated_by")),
            "publication_allowed": False,
            "captured_at": cap.get("captured_at"),
        }
    return {"schema_version": 1, "step": "06_listas_preview",
            "branch": BRANCH, "effects_enabled": False,
            "source_queue_sha": queue_sha,
            "items": items, "count": len(items)}


def _request(method, auth, payload=None):
    url = API + "?ref=" + urllib.parse.quote(BRANCH, safe="") if method == "GET" else API
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + auth,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "TTActualidadV2-Listas",
    }
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if method == "GET" and exc.code == 404:
            return None
        raise RuntimeError("GitHub Listas HTTP %d; no afirmar éxito" % exc.code) from None


def sync_to_github(api, auth, queue, queue_sha):
    """Guardar proyección en rama V2 y exigir readback íntegro.

    GitHub acepta el SHA del blob actual; nunca sobreescribir un cambio
    concurrente a ciegas ni publicar. Se puede volver a sincronizar sin enviar
    otra vez ninguna tendencia.
    """
    expected = build_listas(queue, queue_sha)
    current = _request("GET", auth)
    old = json.loads(base64.b64decode(current["content"])) if current else None
    if old != expected:
        payload = {
            "branch": BRANCH,
            "message": "v2: update preview Listas from captured editorial queue",
            "content": base64.b64encode(
                (json.dumps(expected, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            ).decode("ascii"),
        }
        if current is not None:
            payload["sha"] = current["sha"]
        response = _request("PUT", auth, payload)
        if not response or not response.get("commit", {}).get("sha"):
            raise RuntimeError("No se confirmó escritura de Listas")
    verified = _request("GET", auth)
    if not verified or json.loads(base64.b64decode(verified["content"])) != expected:
        raise RuntimeError("Listas V2 no coincide con cola y revisión")
    return expected


def main():
    import editorial_run_v2 as core
    api = core.module("persist_capture_github.py", "ttv2_listas_github")
    parser = argparse.ArgumentParser()
    parser.add_argument("--sync", action="store_true", help="Permite escribir SOLO la proyección Listas V2")
    args = parser.parse_args()
    auth = api.token()
    queue, sha = core.queue_read(api, auth)
    projected = build_listas(queue, sha)
    print("TT_V2_LISTAS_MODE=" + ("SYNC" if args.sync else "DRY_RUN"), flush=True)
    print("TT_V2_LISTAS_CARDS=" + str(projected["count"]), flush=True)
    print("TT_V2_LISTAS_UNCERTAIN=" + str(sum(
        x["uncertain_cause"] for x in projected["items"].values())), flush=True)
    if not args.sync:
        print("TT_V2_GITHUB_WRITE=NO", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        return
    sync_to_github(api, auth, queue, sha)
    print("TT_V2_LISTAS_VERIFIED=YES", flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_LISTAS_ERROR=" + str(exc), file=sys.stderr, flush=True)
        sys.exit(1)
