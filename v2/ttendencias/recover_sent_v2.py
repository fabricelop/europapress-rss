#!/usr/bin/env python3
"""Recupera un único envío editorial V2 EXISTENTE, sin enviar nuevos mensajes.

Abre Chrome con el perfil exclusivo de V2, lee la URL del diario previo, recupera
una respuesta estable y solo después de cerrar Chrome persiste captured_review.
Nunca modifica V1, main ni producción. No se debe reintentar --run.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request
from playwright.sync_api import sync_playwright

import editorial_run_v2 as core

ROOT = core.ROOT
STOP = core.STOP
DIAGNOSTIC_FIELDS = ("trend_id", "revision", "chat_url")

def journal_path(trend, revision):
    if not re.fullmatch(r"trv2-[a-f0-9]{24}", trend):
        raise ValueError("ID de tendencia V2 incorrecto")
    if revision < 1:
        raise ValueError("Revisión inválida")
    return core.DIAG_DIR / ("run-" + trend + "-r" + str(revision) + ".json")

def no_send_recovery(trend_id, revision):
    log = journal_path(trend_id, revision)
    if not log.exists():
        raise RuntimeError("No existe diario de envío; no se puede reconstruir una conversación")
    record = json.loads(log.read_text(encoding="utf-8-sig"))
    if (record.get("trend_id") != trend_id or record.get("revision") != revision
            or not record.get("lease_token") or not record.get("message_sent")):
        raise RuntimeError("Diario no confirma un único mensaje enviado; sin recuperación")
    if record.get("persisted"):
        print("TT_V2_ALREADY_PERSISTED=YES")
        return
    url = record.get("chat_url") or ""
    valid_url = r"https://chatgpt\.com/c/[A-Za-z0-9-]{16,80}"
    if not re.fullmatch(valid_url, url):
        # Descubrimiento local ya comprobado contra el turno del usuario:
        # identidad, revisión y cierre del Chrome aislado.
        discovery = core.DIAG_DIR / ("discover-" + trend_id + ".json")
        if not discovery.exists():
            raise RuntimeError("Sin URL ni diagnóstico de descubrimiento: NO REENVIAR")
        found = json.loads(discovery.read_text(encoding="utf-8-sig"))
        if (found.get("found") is not True
            or found.get("trend_id") != trend_id
            or found.get("revision") != revision
            or found.get("cleanup_verified") is not True
            or found.get("message_sent") is not False
            or found.get("github_write") is not False):
            raise RuntimeError("Descubrimiento no validado: NO REENVIAR")
        url = found.get("chat_url") or ""
        if not re.fullmatch(valid_url, url):
            raise RuntimeError("URL descubierta inválida: NO REENVIAR")
        print("TT_V2_RECOVER_USING_DISCOVERY=YES", flush=True)
    api = core.module("persist_capture_github.py", "ttv2_gh_recovery")
    state = core.module("editorial_capture_state.py", "ttv2_capture_recovery")
    extractor = core.module("chatgpt_transcript.py", "ttv2_transcript_recovery")
    auth = api.token()
    queue, _ = core.queue_read(api, auth)
    item = queue.get("items", {}).get(trend_id)
    if not item or item.get("revision") != revision:
        raise RuntimeError("El ID o revisión cambiaron, sin persistencia")
    if item.get("status") == "captured_review":
        cap = item.get("capture") or {}
        if cap.get("chat_url") == url and cap.get("revision") == revision:
            print("TT_V2_ALREADY_STAGED=YES")
            return
        raise RuntimeError("Captura existente diferente: intervención manual")
    if item.get("status") not in ("capture_recovery", "in_progress"):
        raise RuntimeError("No recuperar trabajo en estado " + str(item.get("status")))
    intent = item.get("send_intent") or {}
    if intent.get("token") != record["lease_token"]:
        raise RuntimeError("Token de envío local/GitHub no coincide")
    if core.profile_pids():
        raise RuntimeError("Chrome V2 abierto: no interferir con otra ejecución")
    if not core.CHROME.exists():
        raise RuntimeError("Chrome nativo no encontrado")
    result = {"trend_id": trend_id, "revision": revision, "chat_url": url,
              "status": "recovery_started", "message_sent": False,
              "recovery_only": True, "published": False, "reply_captured": False,
              "cleanup_verified": False}
    proc = None
    browser = None
    owned = set()
    try:
        import socket
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        if port in (9223, 9234):
            raise RuntimeError("Puerto reservado por V1")
        proc = subprocess.Popen([str(core.CHROME), f"--user-data-dir={core.PROFILE}",
            f"--remote-debugging-port={port}", "--remote-debugging-address=127.0.0.1",
            "--disable-extensions", "--no-first-run", "--no-default-browser-check",
            "--new-window", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        endpoint = "http://127.0.0.1:" + str(port)
        for _ in range(40):
            try:
                with urllib.request.urlopen(endpoint + "/json/version", timeout=3) as response:
                    json.load(response)
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("Chrome CDP no disponible")
        owned = core.profile_pids()
        if not owned:
            raise RuntimeError("No se identificó el Chrome V2 lanzado")
        print("TT_V2_RECOVERY_CDP=YES", flush=True)
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint)
            ctx = browser.contexts[0]
            page = next((p for p in ctx.pages if p.url == url), None)
            if page is None:
                page = ctx.new_page()
                page.goto(url, wait_until="domcontentloaded", timeout=60000)
            last = ""
            stable = 0
            reload_done = False
            result["load_retries"] = 0
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if page.url != url:
                    time.sleep(2)
                    continue
                body = page.locator("body").inner_text(timeout=8000)
                if "Could not load this ChatGPT conversation" in body:
                    if not reload_done:
                        reload_done = True
                        result["load_retries"] = 1
                        result["first_load_failure"] = True
                        print("TT_V2_SINGLE_READ_ONLY_RELOAD=YES", flush=True)
                        # Una sola recarga del MISMO chat; nunca pulsar Retry ni enviar texto.
                        page.reload(wait_until="domcontentloaded", timeout=45000)
                        time.sleep(3)
                        continue
                    result["status"] = "conversation_load_failed"
                    result["last_reason"] = "conversation_inaccessible_in_v2_profile"
                    result["visible_tail"] = body[-1200:]
                    print("TT_V2_CONVERSATION_LOAD_FAILED=YES", flush=True)
                    break
                answer, reason = extractor.extract_reply(body, trend_id=trend_id, revision=revision)
                stop = page.locator(STOP).count() > 0
                if answer and answer == last:
                    stable += 1
                else:
                    last, stable = answer, 0
                if answer and stable >= 3 and not stop:
                    result["reply_captured"] = True
                    result["answer"] = answer
                    result["status"] = "captured_needs_editorial_validation"
                    result["validation"] = reason
                    break
                time.sleep(2)
            if not result["reply_captured"] and result["status"] != "conversation_load_failed":
                result["status"] = "not_verified"
                result["visible_tail"] = page.locator("body").inner_text(timeout=8000)[-3000:]
                result["last_reason"] = reason
            result["page_url"] = page.url
            result["page_title"] = page.title()
            result["session_signals"] = {
                "login_link_count": page.locator("a[href*='/auth/login'],a[href*='/login']").count(),
                "account_menu_count": page.locator("[data-testid='profile-button'],button[aria-label*='Profile'],button[aria-label*='Perfil']").count(),
                "composer_count": page.locator("#prompt-textarea,[data-testid='prompt-textarea']").count()
            }
            try:
                browser.new_browser_cdp_session().send("Browser.close")
            except Exception:
                pass
    except Exception as exc:
        result["error"] = str(exc)[:400]
        result["status"] = "error"
    finally:
        if browser:
            try: browser.close()
            except Exception: pass
        if proc:
            try: proc.wait(timeout=10)
            except subprocess.TimeoutExpired: pass
        remaining = core.profile_pids()
        for pid in remaining & owned:
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True, timeout=15)
        time.sleep(2)
        remaining = core.profile_pids()
        result["remaining_v2_pids"] = sorted(remaining)
        result["cleanup_verified"] = bool(proc) and not remaining
        core.store(core.DIAG_DIR / ("recover-" + trend_id + ".json"), result)
        print("TT_V2_RECOVERY_CAPTURED=" + ("YES" if result["reply_captured"] else "NO"))
        print("TT_V2_REMAINING_PROCESSES=" + str(len(remaining)))
    if not result["reply_captured"] or not result["cleanup_verified"]:
        print("TT_V2_NO_RESEND=YES")
        print("TT_V2_PUBLISHED=NO")
        raise RuntimeError("Conversación pendiente de recuperación; diagnóstico guardado")
    current, sha = core.queue_read(api, auth)
    staged, status = state.stage_capture(current, trend_id=trend_id,
        revision=revision, answer=result["answer"], chat_url=url,
        validated_capture=True, lease_token=record["lease_token"])
    if status != "already_staged":
        core.queue_write(api, auth, sha, staged, "recover captured editorial " + trend_id)
    verify, _ = core.queue_read(api, auth)
    cap = (verify["items"][trend_id].get("capture") or {})
    digest = hashlib.sha256(result["answer"].strip().encode("utf-8")).hexdigest()
    if (verify["items"][trend_id]["status"] != "captured_review"
        or cap.get("sha256") != digest or cap.get("answer") != result["answer"].strip()
        or cap.get("editorial_validated") is not False):
        raise RuntimeError("Lectura de verificación de GitHub fallida; NO reenviar")
    record["persisted"] = True
    record["chat_url"] = url
    record["status"] = "persisted_captured_review"
    core.store(log, record)
    print("TT_V2_RECOVERY_STATUS=staged_pending_editorial_review")
    print("TT_V2_GITHUB_VERIFIED=YES")
    print("TT_V2_NO_RESEND=YES")
    print("TT_V2_PUBLISHED=NO")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--trend-id", required=True)
    p.add_argument("--revision", required=True, type=int)
    args = p.parse_args()
    no_send_recovery(args.trend_id, args.revision)

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_RECOVERY_ERROR=" + str(exc), file=sys.stderr)
        print("TT_V2_PUBLISHED=NO")
        sys.exit(1)
