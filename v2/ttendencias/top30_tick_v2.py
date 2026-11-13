#!/usr/bin/env python3
"""Reloj V2 cada 15 min: dispara la captación existente mediante commit aislado.

NO ejecuta ChatGPT, no publica, no escribe en main, no toca perfiles Chrome.
La captura la realiza el workflow de pasos 1-4 de la rama V2, disparado por push.
La tarea de Windows se instala aparte; sin --tick solamente consulta/diagnostica.
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
REPO = "fabricelop/europapress-rss"
PATH = "v2/ttendencias/manual-run-trigger.txt"
API = "https://api.github.com/repos/" + REPO + "/contents/" + PATH
SLOT_KEY = "TT_V2_REFRESH_SLOT_UTC="
SLOT_PATTERN = re.compile(r"(?m)^TT_V2_REFRESH_SLOT_UTC=(\d{4}-\d\d-\d\dT\d\d:\d\d:00Z)$")


def quarter_slot(now=None):
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise ValueError("Se requiere reloj UTC con zona horaria")
    utc = now.astimezone(timezone.utc)
    return utc.replace(minute=(utc.minute // 15) * 15,
                       second=0, microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def should_trigger(content, slot):
    found = SLOT_PATTERN.search(content or "")
    return found is None or found.group(1) < slot


def request(method, auth, payload=None):
    uri = API + "?ref=" + urllib.parse.quote(BRANCH, safe="") if method == "GET" else API
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + auth,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "TTActualidadV2-Top30-15m",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(uri, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        if exc.code in (409, 412, 422):
            raise RuntimeError("Otro proceso cambió el trigger: no reintentar sin comprobar") from None
        raise RuntimeError("GitHub HTTP %d; trigger NO confirmado" % exc.code) from None


def tick(auth, slot, *, execute=False):
    current = request("GET", auth)
    if not current or not current.get("sha"):
        raise RuntimeError("No se ha podido leer el trigger V2")
    original = base64.b64decode(current["content"]).decode("utf-8")
    if not should_trigger(original, slot):
        return "ALREADY_REQUESTED"
    if not execute:
        return "WOULD_REQUEST"
    content = (SLOT_KEY + slot + "\n"
               + "Solicitud de captura de GetDayTrends de V2. "
               + "No ejecución editorial, sin publicación.\n")
    payload = {
        "branch": BRANCH,
        "sha": current["sha"],
        "message": "v2: request Top30 15-min capture " + slot,
        "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
    }
    response = request("PUT", auth, payload)
    if not (response or {}).get("commit", {}).get("sha"):
        raise RuntimeError("El push de V2 no está confirmado")
    verify = request("GET", auth)
    saved = base64.b64decode(verify["content"]).decode("utf-8")
    if SLOT_KEY + slot not in saved:
        raise RuntimeError("No coincide el trigger leído de GitHub")
    return "SUBMITTED"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tick", action="store_true",
                        help="Autoriza un commit SOLO al trigger de la rama V2")
    args = parser.parse_args()
    # Reusar el login GitHub ya empleado por el consumidor.
    from persist_capture_github import token
    slot = quarter_slot()
    result = tick(token(), slot, execute=args.tick)
    print("TT_V2_TOP30_SLOT_UTC=" + slot, flush=True)
    print("TT_V2_TOP30_TRIGGER=" + result, flush=True)
    print("TT_V2_TOP30_REFRESH_RESULT=WORKFLOW_PENDING" if result == "SUBMITTED"
          else "TT_V2_TOP30_REFRESH_RESULT=NO_NEW_CAPTURE_REQUESTED", flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_TOP30_TICK_ERROR=" + str(exc), file=sys.stderr, flush=True)
        sys.exit(1)
