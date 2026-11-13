#!/usr/bin/env python3
"""TTActualidad V2: persistir respuesta CDP en la cola V2 usando GitHub REST.

Se ejecuta localmente después del cierre verificado de Chrome. No abre ChatGPT.
Requiere una autenticación GitHub ya configurada: GH_TOKEN/GITHUB_TOKEN o gh auth.
Jamás usa la rama main, no publica y no escribe en rutas de V1.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(os.environ["LOCALAPPDATA"]) / "TTActualidadV2"
DIAG = ROOT / "diagnostics" / "recover-svfinal-cdp.json"
STATE = pathlib.Path(__file__).with_name("editorial_capture_state.py")
API = "https://api.github.com/repos/fabricelop/europapress-rss/contents/v2/ttendencias/state/editorial-queue.json"
BRANCH = "feature/ttactualidad-v2-clean"
VALIDATION = "paired_turn_id_revision_footer_and_stable_idle"

def load_state():
    spec = importlib.util.spec_from_file_location("ttv2_capture_state", STATE)
    if spec is None or spec.loader is None:
        raise RuntimeError("Módulo de estados V2 no disponible")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def token():
    value = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if value:
        return value.strip()
    try:
        result = subprocess.run(["gh", "auth", "token"], capture_output=True,
                                text=True, timeout=15, check=True)
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise RuntimeError("Falta autenticación: gh auth login o variable GH_TOKEN")

def request(method, auth, payload=None):
    url = API + "?ref=" + urllib.parse.quote(BRANCH, safe="") if method == "GET" else API
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Accept": "application/vnd.github+json",
               "Authorization": "Bearer " + auth,
               "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "TTActualidadV2-capture"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, headers=headers, data=body, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (409, 412, 422):
            raise RuntimeError("GitHub conflict/changed revision (HTTP %d), no retry" % exc.code)
        raise RuntimeError("GitHub HTTP %d, no commit verified" % exc.code)

def read_diag(path):
    d = json.loads(path.read_text(encoding="utf-8-sig"))
    if (d.get("reply_captured") is not True or d.get("cleanup_verified") is not True
        or d.get("status") != "captured_needs_editorial_validation"
        or d.get("validation") != VALIDATION
        or d.get("message_sent") or d.get("published") or d.get("queue_modified")):
        raise ValueError("Diagnóstico de captura V2 no validado")
    if not isinstance(d.get("answer"), str) or len(d["answer"].strip()) < 80:
        raise ValueError("Respuesta vacía/incompleta")
    if not isinstance(d.get("revision"), int) or d["revision"] < 1:
        raise ValueError("Revisión inválida")
    return d

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--diagnostic", type=pathlib.Path, default=DIAG)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    d = read_diag(args.diagnostic)
    auth = token()
    current = request("GET", auth)
    raw = base64.b64decode(current["content"]).decode("utf-8")
    queue = json.loads(raw)
    state = load_state()
    staged, status = state.stage_capture(
        queue, trend_id=d["trend_id"], revision=d["revision"],
        answer=d["answer"], chat_url=d["chat_url"],
        validated_capture=True, observed_at=d.get("observed_at"),
        lease_token=d.get("lease_token")
    )
    digest = hashlib.sha256(d["answer"].strip().encode("utf-8")).hexdigest()
    print("TT_V2_CAPTURE_SHA256=" + digest, flush=True)
    print("TT_V2_STAGE_STATUS=" + status, flush=True)
    if args.dry_run:
        print("TT_V2_GITHUB_WRITE=NO", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        return
    if status == "already_staged":
        print("TT_V2_GITHUB_WRITE=NO", flush=True)
        print("TT_V2_GITHUB_VERIFIED=YES", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        return
    payload = {
        "message": "v2: stage captured editorial reply " + d["trend_id"] + " r" + str(d["revision"]),
        "branch": BRANCH,
        "sha": current["sha"],
        "content": base64.b64encode((json.dumps(staged, ensure_ascii=False, indent=2)
                                      + "\n").encode("utf-8")).decode("ascii")
    }
    response = request("PUT", auth, payload)
    commit = response.get("commit", {}).get("sha")
    if not commit:
        raise RuntimeError("GitHub no confirmó SHA de commit")
    verified = request("GET", auth)
    item = json.loads(base64.b64decode(verified["content"]))["items"][d["trend_id"]]
    cap = item.get("capture") or {}
    if not (item.get("status") == "captured_review"
            and item.get("revision") == d["revision"]
            and cap.get("answer") == d["answer"].strip()
            and cap.get("sha256") == digest
            and cap.get("editorial_validated") is False):
        raise RuntimeError("ALERTA: comprobación de lectura GitHub fallida")
    print("TT_V2_GITHUB_COMMIT=" + commit, flush=True)
    print("TT_V2_GITHUB_WRITE=YES", flush=True)
    print("TT_V2_GITHUB_VERIFIED=YES", flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_PERSIST_ERROR=" + str(exc), file=sys.stderr, flush=True)
        print("TT_V2_GITHUB_VERIFIED=NO", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        sys.exit(1)
