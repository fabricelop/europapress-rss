#!/usr/bin/env python3
"""Rescate supervisado de un chat V2 YA enviado y terminado.

NUNCA abre un chat nuevo ni escribe prompts. Debe ejecutarse cuando NO esté
corriendo el consumidor (lock exclusivo). Se conecta SOLO al Chrome V2
existente por CDP y comprueba ID/revisión/lease antes de capturar y persistir.
NO toca perfiles de V1, no publica, no modifica main.
"""
import argparse
import contextlib
import base64
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time
from playwright.sync_api import sync_playwright

import editorial_run_v2 as core
from process_lock_v2 import exclusive_v2_lock, AlreadyRunning

LOCK = core.ROOT / "editorial_batch_v2.lock"
JOURNAL_NAME = "run-{trend_id}-r{revision}.json"
CHAT_RE = re.compile(r"^https://chatgpt\.com/c/[A-Za-z0-9-]{16,80}$")


def running_cdp_port():
    """Leer solamente el puerto del root Chrome cuyo perfil es V2."""
    ps = (
        "$p=(Join-Path $env:LOCALAPPDATA 'TTActualidadV2\\ChromeProfile');"
        "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | "
        "Where-Object { $_.CommandLine -and "
        "$_.CommandLine.Contains('--user-data-dir=') -and "
        "$_.CommandLine.Contains($p) -and "
        "$_.CommandLine -notmatch '(?:^|\\s)--type=' } | "
        "Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress"
    )
    result = subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps],
                            capture_output=True, text=True, timeout=25)
    if result.returncode:
        raise RuntimeError("No se pudo comprobar el proceso Chrome V2")
    rows = json.loads(result.stdout) if result.stdout.strip() else []
    if isinstance(rows, dict):
        rows = [rows]
    ports = set()
    for row in rows:
        match = re.search(r"--remote-debugging-port=(\d+)",
                          row.get("CommandLine") or "")
        if match:
            ports.add(int(match.group(1)))
    if len(ports) != 1:
        raise RuntimeError("Se esperaba un único Chrome V2 con CDP; no recuperar")
    port = ports.pop()
    if port in (9223, 9234) or not 1024 <= port <= 65535:
        raise RuntimeError("El puerto detectado no es exclusivo de V2")
    return port


def journal_for(trend_id, revision):
    path = core.DIAG_DIR / JOURNAL_NAME.format(trend_id=trend_id, revision=revision)
    if not path.exists():
        raise RuntimeError("Falta diario local del envío: no hay recuperación segura")
    record = json.loads(path.read_text(encoding="utf-8-sig"))
    if (record.get("trend_id") != trend_id or record.get("revision") != revision
        or record.get("message_sent") is not True
        or not record.get("lease_token")
        or record.get("published") is not False):
        raise RuntimeError("Diario V2 no confirma el envío único de este trabajo")
    return path, record


def confirm_remote(api, auth, record):
    queue, _ = core.queue_read(api, auth)
    item = queue.get("items", {}).get(record["trend_id"]) or {}
    if (item.get("revision") != record["revision"]
        or item.get("status") not in ("in_progress", "capture_recovery")
        or (item.get("send_intent") or {}).get("token") != record["lease_token"]):
        raise RuntimeError("La cola remota no confirma la misma revisión y envío")
    return item


def find_existing_page(browser, trend_id, revision, expected_url):
    tracker = core.module("chatgpt_target_tracker.py", "ttv2_existing_tracker")
    matches = []
    for context in list(browser.contexts):
        for page in list(context.pages):
            canonical = tracker.canonical(page.url)
            if not CHAT_RE.fullmatch(canonical):
                continue
            if expected_url and canonical != expected_url:
                continue
            if tracker.verify_conversation(page, trend_id, revision):
                matches.append(page)
    if len(matches) != 1:
        raise RuntimeError("No se identificó UNA conversación V2 existente: no recuperar")
    return matches[0]


def persist_existing(api, auth, state, record, journal):
    digest = hashlib.sha256(record["answer"].strip().encode("utf-8")).hexdigest()
    for attempt in range(5):
        queue, sha = core.queue_read(api, auth)
        staged, status = state.stage_capture(
            queue, trend_id=record["trend_id"], revision=record["revision"],
            answer=record["answer"], chat_url=record["chat_url"],
            validated_capture=True, observed_at=core.utcnow(),
            lease_token=record["lease_token"])
        if status == "already_staged":
            break
        try:
            core.queue_write(api, auth, sha, staged,
                             "recover existing chat " + record["trend_id"])
            break
        except RuntimeError as exc:
            if "GitHub conflict/changed revision" not in str(exc) or attempt == 4:
                raise
            time.sleep(1 + attempt)
    verified, sha = core.queue_read(api, auth)
    item = verified["items"][record["trend_id"]]
    cap = item.get("capture") or {}
    if (item["status"] != "captured_review" or cap.get("sha256") != digest
        or cap.get("answer") != record["answer"].strip()
        or cap.get("chat_url") != record["chat_url"]):
        raise RuntimeError("Persistencia GitHub de respuesta existente sin verificar")
    record["status"] = "persisted_captured_review"
    record["persisted"] = True
    core.store(journal, record)
    print("TT_V2_RECOVERY_GITHUB_VERIFIED=YES", flush=True)
    listas = core.module("listas_v2.py", "ttv2_existing_listas")
    projection = listas.sync_to_github(api, auth, verified, sha)
    if not projection["items"].get(record["trend_id"]):
        raise RuntimeError("La ficha recuperada no aparece en Listas")
    print("TT_V2_RECOVERY_LISTAS_VERIFIED=YES", flush=True)
    web = core.module("web_top30_v2.py", "ttv2_existing_web")
    projection = web.sync_to_github(auth)
    in_top30 = next((t for t in projection["items"]
                     if t["trend_id"] == record["trend_id"]), None)
    if in_top30 is not None and (in_top30["status"] != "explicada"
                                 or in_top30["explanation"] != record["answer"]):
        raise RuntimeError("La web no refleja el chat recuperado")
    print("TT_V2_RECOVERY_WEB_VERIFIED=YES", flush=True)


def recover(trend_id, revision, *, lock_held=False):
    # En el reinicio solo el proceso encargado puede rescatar un chat V2.
    with (contextlib.nullcontext() if lock_held else exclusive_v2_lock(LOCK)):
        journal, record = journal_for(trend_id, revision)
        api = core.module("persist_capture_github.py", "ttv2_existing_api")
        state = core.module("editorial_capture_state.py", "ttv2_existing_state")
        transcript = core.module("chatgpt_transcript.py", "ttv2_existing_transcript")
        auth = api.token()
        confirm_remote(api, auth, record)
        if record.get("reply_captured") and record.get("cleanup_verified"):
            if not record.get("answer") or not record.get("chat_url"):
                raise RuntimeError("Diario de recuperación inconsistente")
            persist_existing(api, auth, state, record, journal)
            return
        owned = core.profile_pids()
        if not owned:
            raise RuntimeError("Chrome V2 no está abierto; recuperación distinta necesaria")
        port = running_cdp_port()
        print("TT_V2_RECOVERY_EXISTING_CDP=YES", flush=True)
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(
                "http://127.0.0.1:" + str(port), timeout=18000)
            candidate = (record.get("chat_url") or "").split("?",1)[0]
            if candidate and not CHAT_RE.fullmatch(candidate):
                raise RuntimeError("URL del diario V2 inválida")
            page = find_existing_page(browser, trend_id, revision, candidate)
            print("TT_V2_RECOVERY_CHAT_IDENTITY_VERIFIED=YES", flush=True)
            result = transcript.capture_existing_page(
                page, trend_id=trend_id, revision=revision,
                seconds=90, allow_single_reload=False)
            record["capture_diagnostic"] = {
                "status": result["status"], "reason": result["reason"],
                "observations": result["observations"]}
            if result["status"] != "captured":
                core.store(journal, record)
                raise RuntimeError("Respuesta no capturable; conservar chat, no reenviar")
            if candidate and result["url"].split("?",1)[0] != candidate:
                raise RuntimeError("La URL del chat cambió durante el rescate")
            record["answer"] = result["answer"]
            record["chat_url"] = result["url"].split("?",1)[0]
            record["reply_captured"] = True
            record["status"] = "captured_needs_editorial_validation"
            record["validation"] = "paired_turn_id_revision_dom_or_footer_and_stable_idle"
            core.store(journal, record)
            print("TT_V2_RECOVERY_REPLY_CAPTURED=YES", flush=True)
            # Sólo tras capturar y verificar la identidad, cerrar Chrome V2.
            try:
                session = browser.new_browser_cdp_session()
                session.send("Browser.close")
            except Exception:
                pass
            try:
                browser.close()
            except Exception:
                pass
        time.sleep(3)
        remaining = core.profile_pids()
        for pid in remaining & owned:
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True, timeout=15)
        time.sleep(2)
        remaining = core.profile_pids()
        record["remaining_v2_pids"] = sorted(remaining)
        record["cleanup_verified"] = not remaining
        core.store(journal, record)
        if remaining:
            raise RuntimeError("Chrome V2 no cerrado: no confirmar recuperación")
        print("TT_V2_RECOVERY_CHROME_CLOSED=YES", flush=True)
        persist_existing(api, auth, state, record, journal)
        print("TT_V2_RECOVERY_COMPLETED=YES", flush=True)


def recover_orphan_automatically():
    """Rescata el ÚNICO trabajo en ChatGPT ya enviado si quedó Chrome abierto.

    No genera prompts ni elimina diarios, no usa ni modifica ninguna cola V1.
    Si falta evidencia unívoca, detiene el arranque automático sin cerrar Chrome.
    """
    if not core.profile_pids():
        print("TT_V2_RECOVERY_ORPHAN=NONE", flush=True)
        return "none"
    # Solo el worker previo pudo tener Chrome V2 abierto en este perfil.
    api = core.module("persist_capture_github.py", "ttv2_orphan_github")
    auth = api.token()
    queue, _ = core.queue_read(api, auth)
    candidates = []
    for item in queue.get("items", {}).values():
        if item.get("status") not in ("in_progress", "capture_recovery"):
            continue
        intent = item.get("send_intent") or {}
        if not intent.get("token"):
            continue
        path = core.DIAG_DIR / JOURNAL_NAME.format(
            trend_id=item["trend_id"], revision=item["revision"])
        if not path.exists():
            continue
        try:
            journal = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        if (journal.get("trend_id") == item["trend_id"]
            and journal.get("revision") == item["revision"]
            and journal.get("message_sent") is True
            and journal.get("lease_token") == intent["token"]
            and CHAT_RE.fullmatch((journal.get("chat_url") or "").split("?", 1)[0])):
            candidates.append(item)
    if len(candidates) != 1:
        raise RuntimeError("Chrome V2 huérfano sin UN envío identificado: conservarlo y bloquear reinicio")
    item = candidates[0]
    print("TT_V2_RECOVERY_ORPHAN_ID=" + item["trend_id"], flush=True)
    recover(item["trend_id"], item["revision"])
    print("TT_V2_RECOVERY_ORPHAN=VERIFIED", flush=True)
    return "recovered"


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--trend-id")
    group.add_argument("--auto", action="store_true",
                       help="Solo rescatar una sesión V2 huérfana unívoca; sin envío")
    parser.add_argument("--revision", type=int)
    args = parser.parse_args()
    if args.auto:
        if args.revision is not None:
            parser.error("--auto no admite --revision")
        recover_orphan_automatically()
        return
    if not re.fullmatch(r"trv2-[0-9a-f]{24}", args.trend_id):
        parser.error("El ID no es una tendencia V2 válida")
    if args.revision is None or args.revision < 1:
        parser.error("Se requiere revisión positiva")
    recover(args.trend_id, args.revision)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_RECOVERY_ERROR=" + str(exc), file=sys.stderr, flush=True)
        print("TT_V2_RECOVERY_NO_RESEND=YES", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        sys.exit(1)
