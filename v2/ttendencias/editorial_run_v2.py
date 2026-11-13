#!/usr/bin/env python3
"""TTActualidad V2: una elaboración completa en Chrome aislado.

Usar --check antes de --run. No publica, no toca V1, no reenvía si hay
indicios de envío previo. Cada operación GitHub es sobre la rama V2.
"""
import argparse
import base64
import copy
import hashlib
import importlib.util
import json
import os
import pathlib
import secrets
import socket
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(os.environ["LOCALAPPDATA"]) / "TTActualidadV2"
PROFILE = ROOT / "ChromeProfile"
DIAG_DIR = ROOT / "diagnostics"
CHROME = pathlib.Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Google" / "Chrome" / "Application" / "chrome.exe"
COMPOSERS = ("#prompt-textarea", "[data-testid='prompt-textarea']", "[contenteditable='true'][role='textbox']")
STOP = "[data-testid='stop-button'],button[aria-label*='Stop'],button[aria-label*='Detener']"
BRANCH = "feature/ttactualidad-v2-clean"

def module(filename, name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(__file__).with_name(filename))
    if not spec or not spec.loader:
        raise RuntimeError("Falta módulo V2: " + filename)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj

def utcnow():
    return datetime.now(timezone.utc).isoformat()

def store(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)

def queue_read(api, auth):
    fetched = api.request("GET", auth)
    q = json.loads(base64.b64decode(fetched["content"]).decode("utf-8"))
    if q.get("effects_enabled") is not False or q.get("step") != "04_editorial_queue":
        raise RuntimeError("No es la cola editorial V2 segura")
    return q, fetched["sha"]

def queue_write(api, auth, sha, q, message):
    payload = {"branch": BRANCH, "sha": sha, "message": "v2: " + message,
               "content": base64.b64encode((json.dumps(q, ensure_ascii=False, indent=2)
                                              + "\n").encode("utf-8")).decode("ascii")}
    response = api.request("PUT", auth, payload)
    if not response.get("commit", {}).get("sha"):
        raise RuntimeError("GitHub no confirmó commit; revisar antes de reintentar")
    return response["commit"]["sha"]

def selected(queue, trend_id):
    if not trend_id:
        raise RuntimeError("Se necesita --trend-id explícito; no procesar toda la cola por error")
    item = queue["items"].get(trend_id)
    if not item:
        raise RuntimeError("Tendencia no encontrada en la cola V2")
    if item.get("status") not in ("pending", "review_pending"):
        raise RuntimeError("NO_SEND: trabajo " + item.get("status", "unknown"))
    if item.get("send_intent") or item.get("capture"):
        raise RuntimeError("NO_SEND: existe envío o captura anterior")
    return item

def profile_pids():
    ps = (
        "$p=$env:LOCALAPPDATA+'\\TTActualidadV2\\ChromeProfile';"
        "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | "
        "Where-Object { $_.CommandLine -and $_.CommandLine.Contains('--user-data-dir=') "
        "-and $_.CommandLine.Contains($p) } | "
        "Select-Object -ExpandProperty ProcessId | ConvertTo-Json -Compress"
    )
    run = subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps],
                         capture_output=True, text=True, timeout=20)
    if run.returncode:
        raise RuntimeError("No se pudo inspeccionar Chrome V2")
    raw = run.stdout.strip()
    value = json.loads(raw) if raw else []
    return set(map(int, value if isinstance(value, list) else [value]))

def prompt_for(item):
    return (
        "TTActualidad V2. ELABORACIÓN EDITORIAL DE UNA SOLA TENDENCIA. "
        "NO PUBLICAR NI MODIFICAR GITHUB. Investiga por qué es tendencia hoy en España "
        + item["name"] + ". Comprueba el motivo con fuentes actuales fiables; "
        "si no puedes verificarlo, indícalo y no inventes hechos. "
        "Responde con una explicación periodística breve, hashtags relevantes, "
        "un solo remate suave cuando proceda y enlaces HTTPS completos de fuentes. "
        "Identificador: " + item["trend_id"] + ". Revisión: " + str(item["revision"]) + "."
    )

def run_one(api, state, transcript, auth, item):
    trend_id, revision = item["trend_id"], item["revision"]
    journal = DIAG_DIR / ("run-" + trend_id + "-r" + str(revision) + ".json")
    if journal.exists():
        raise RuntimeError("NO_SEND: diario local existente; investigar, no reenviar")
    if profile_pids():
        raise RuntimeError("Chrome V2 ya abierto; no interferir")
    if not CHROME.exists():
        raise RuntimeError("Chrome no encontrado")
    token = secrets.token_hex(24)
    q, sha = queue_read(api, auth)
    current = selected(q, trend_id)
    if current["revision"] != revision:
        raise RuntimeError("Revisión cambiada; no enviar")
    # Reserva CAS, con token exclusivo.
    now = datetime.now(timezone.utc)
    q["items"][trend_id]["status"] = "in_progress"
    q["items"][trend_id]["attempts"] = int(current.get("attempts", 0)) + 1
    q["items"][trend_id]["lease"] = {
        "token": token, "worker_id": "ttv2-native-cdp",
        "started_at": now.isoformat(),
        "expires_at": (now + timedelta(minutes=25)).isoformat()}
    queue_write(api, auth, sha, q, "claim " + trend_id)
    record = {"trend_id": trend_id, "revision": revision, "lease_token": token,
              "message_sent": False, "reply_captured": False, "cleanup_verified": False,
              "queue_modified": True, "published": False,
              "status": "claimed", "observed_at": utcnow()}
    store(journal, record)
    proc = None
    browser = None
    owned = set()
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        if port in (9223, 9234):
            raise RuntimeError("Puerto de V1 reservado")
        proc = subprocess.Popen([str(CHROME), f"--user-data-dir={PROFILE}",
            f"--remote-debugging-port={port}", "--remote-debugging-address=127.0.0.1",
            "--disable-extensions", "--no-first-run", "--no-default-browser-check",
            "--new-window", "https://chatgpt.com/"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        endpoint = "http://127.0.0.1:" + str(port)
        import urllib.request
        for _ in range(40):
            try:
                with urllib.request.urlopen(endpoint + "/json/version", timeout=3) as response:
                    json.load(response)
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("CDP no disponible")
        owned = profile_pids()
        if not owned:
            raise RuntimeError("No se identificaron procesos Chrome V2 propios")
        print("TT_V2_CDP_CONNECTED=YES", flush=True)
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint)
            context = browser.contexts[0]
            page = next((p for p in context.pages if p.url.startswith("https://chatgpt.com/")), None)
            if page is None:
                page = context.new_page()
                page.goto("https://chatgpt.com/", wait_until="domcontentloaded", timeout=45000)
            composer = None
            until = time.monotonic() + 100
            while time.monotonic() < until:
                for selector in COMPOSERS:
                    element = page.locator(selector).first
                    if element.count() and element.is_visible() and element.is_enabled():
                        composer = element
                        break
                if composer:
                    break
                time.sleep(2)
            if composer is None or not page.url.startswith("https://chatgpt.com/"):
                raise RuntimeError("ChatGPT no está listo; no enviar")
            # CRÍTICO: registrar intención en GitHub ANTES de pulsar Enter.
            # Si el proceso muere a continuación, NO puede reenviarse.
            q, sha = queue_read(api, auth)
            live = q["items"].get(trend_id, {})
            if (live.get("status") != "in_progress" or live.get("revision") != revision
                or (live.get("lease") or {}).get("token") != token):
                raise RuntimeError("Reserva invalidada antes del envío")
            live["send_intent"] = {"token": token, "at": utcnow()}
            live["updated_at"] = utcnow()
            queue_write(api, auth, sha, q, "send intent " + trend_id)
            record["status"] = "send_intent_recorded"
            store(journal, record)
            composer.fill(prompt_for(item))
            composer.press("Enter")  # UNA sola pulsación. No reintentar.
            record["message_sent"] = True
            record["status"] = "sent_waiting_for_reply"
            store(journal, record)
            # La interfaz puede abrir la conversación en otra pestaña/target
            # de Chrome. No asumir que la pestaña del composer sigue siendo
            # la conversación después de Enter. Identificar por el ID del
            # prompt, nunca por título de pestaña o URL solamente.
            def matching_conversation():
                checked = []
                for ctx in list(browser.contexts):
                    for candidate in list(ctx.pages):
                        try:
                            url = candidate.url
                            if not url.startswith("https://chatgpt.com/"):
                                continue
                            body = candidate.locator("body").inner_text(timeout=3500)
                            id_seen = trend_id in body
                            revision_seen = ("Revisión: " + str(revision) in body or
                                             "revision " + str(revision) in body.lower())
                            checked.append({"url": url, "id_seen": id_seen,
                                            "revision_seen": revision_seen,
                                            "body_chars": len(body)})
                            if url.startswith("https://chatgpt.com/c/") and id_seen and revision_seen:
                                return candidate, checked
                        except Exception as exc:
                            checked.append({"url": candidate.url,
                                            "error_type": type(exc).__name__})
                return None, checked

            # Capturar la URL tan pronto aparezca, INDEPENDIENTE de la respuesta.
            # La navegación SPA puede tardar; mantener diario incluso si falla
            # la posterior recuperación del texto.
            url_deadline = time.monotonic() + 45
            seen_pages = []
            while time.monotonic() < url_deadline:
                matched, seen_pages = matching_conversation()
                if matched is not None:
                    page = matched
                    record["chat_url"] = page.url.split("?", 1)[0]
                    store(journal, record)
                    print("TT_V2_CHAT_URL_RECORDED=YES", flush=True)
                    break
                time.sleep(0.5)
            if not record.get("chat_url"):
                record["cdp_pages_at_url_timeout"] = seen_pages
                try:
                    session = browser.new_browser_cdp_session()
                    targets = session.send("Target.getTargets").get("targetInfos", [])
                    record["cdp_targets_at_url_timeout"] = [
                        {"type": t.get("type"), "url": t.get("url", ""),
                         "title": t.get("title", "")}
                        for t in targets if "chatgpt.com" in t.get("url", "")
                    ][:25]
                except Exception as exc:
                    record["cdp_target_diagnostic_error"] = type(exc).__name__
                store(journal, record)
                print("TT_V2_CHAT_URL_RECORDED=NO", flush=True)
            print("TT_V2_MESSAGE_SENT_ONCE=YES", flush=True)
            # Lectura sobre LA MISMA sesion, con una unica recarga del chat
            # si la pagina falla. Nunca repite el envio ni pulsa botones.
            capture = transcript.capture_existing_page(
                page, trend_id=trend_id, revision=revision, seconds=240)
            record["capture_diagnostic"] = {
                "status": capture["status"],
                "reason": capture["reason"],
                "reloads": capture["reloads"],
                "observations": capture["observations"]
            }
            if capture["url"].startswith("https://chatgpt.com/c/"):
                record["chat_url"] = capture["url"].split("?", 1)[0]
            if capture["status"] == "captured":
                record.update({
                    "reply_captured": True, "answer": capture["answer"],
                    "status": "captured_needs_editorial_validation",
                    "validation": "paired_turn_id_revision_footer_and_stable_idle"})
                print("TT_V2_REPLY_CAPTURED=YES", flush=True)
            else:
                record["status"] = "capture_recovery_required"
                print("TT_V2_REPLY_CAPTURED=NO", flush=True)
                print("TT_V2_CAPTURE_REASON=" + capture["reason"], flush=True)
            store(journal, record)
            try:
                browser.new_browser_cdp_session().send("Browser.close")
            except Exception:
                pass
    except Exception as exc:
        record["error"] = str(exc)[:500]
        record["status"] = "error_needs_review"
        store(journal, record)
        raise
    finally:
        if browser:
            try: browser.close()
            except Exception: pass
        if proc:
            try: proc.wait(timeout=10)
            except subprocess.TimeoutExpired: pass
        remaining = profile_pids()
        for pid in remaining & owned:
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True, timeout=15)
        time.sleep(2)
        remaining = profile_pids()
        record["remaining_v2_pids"] = sorted(remaining)
        record["cleanup_verified"] = bool(proc) and not remaining
        store(journal, record)
        print("TT_V2_REMAINING_PROCESSES=" + str(len(remaining)), flush=True)
    if not record["reply_captured"] or not record["cleanup_verified"]:
        # Asegurar un estado de recuperación persistente sin reabrir otro chat.
        # La cola tiene send_intent: NUNCA devolverla a pending.
        try:
            fresh, sha = queue_read(api, auth)
            live = fresh["items"].get(trend_id, {})
            if (live.get("status") == "in_progress"
                and live.get("revision") == revision
                and (live.get("send_intent") or {}).get("token") == token):
                live["status"] = "capture_recovery"
                live["capture_recovery_reason"] = record.get("capture_diagnostic", {}).get("reason", "not_verified")
                live.pop("lease", None)
                live["updated_at"] = utcnow()
                fresh["pending_ids"] = [i["trend_id"] for i in sorted(
                    fresh["items"].values(), key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
                    if i["status"] in ("pending", "review_pending", "in_progress", "capture_recovery", "captured_review")]
                fresh["pending_count"] = len(fresh["pending_ids"])
                queue_write(api, auth, sha, fresh, "quarantine interrupted capture " + trend_id)
                print("TT_V2_CAPTURE_RECOVERY_STAGED=YES", flush=True)
        except Exception as error:
            record["quarantine_error"] = str(error)[:200]
            store(journal, record)
            print("TT_V2_CAPTURE_RECOVERY_STAGED=NO", flush=True)
        raise RuntimeError("Captura/cierre no verificados: recuperar sin reenviar")
    # Guardar tras cerrar. El token impide cerrar la reserva de otro consumidor.
    fresh, sha = queue_read(api, auth)
    staged, status = state.stage_capture(fresh,
        trend_id=trend_id, revision=revision, answer=record["answer"],
        chat_url=record["chat_url"], validated_capture=True,
        observed_at=record["observed_at"], lease_token=token)
    if status != "already_staged":
        queue_write(api, auth, sha, staged, "capture " + trend_id)
    verify, _ = queue_read(api, auth)
    cap = verify["items"][trend_id].get("capture") or {}
    if (verify["items"][trend_id]["status"] != "captured_review"
        or cap.get("sha256") != hashlib.sha256(record["answer"].strip().encode()).hexdigest()
        or cap.get("editorial_validated") is not False):
        raise RuntimeError("Persistencia no verificada; no volver a enviar")
    record["status"] = "persisted_captured_review"
    record["persisted"] = True
    store(journal, record)
    print("TT_V2_GITHUB_VERIFIED=YES", flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)

def main():
    parser = argparse.ArgumentParser()
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--trend-id")
    target.add_argument("--next", action="store_true", help="Selecciona automáticamente la próxima tendencia sin envío previo")
    parser.add_argument("--run", action="store_true", help="Habilita un único envío real")
    args = parser.parse_args()
    api = module("persist_capture_github.py", "ttv2_github")
    state = module("editorial_capture_state.py", "ttv2_state")
    transcript = module("chatgpt_transcript.py", "ttv2_transcript")
    auth = api.token()
    q, _ = queue_read(api, auth)
    if args.next:
        eligible = sorted((x for x in q["items"].values()
            if x.get("status") in ("pending", "review_pending")
            and not x.get("send_intent") and not x.get("capture")
            and int(x.get("attempts", 0)) < 3),
            key=lambda x: (x.get("requested_at", ""), x["trend_id"]))
        if not eligible:
            print("TT_V2_NO_ELIGIBLE_JOB=YES")
            return
        item = selected(q, eligible[0]["trend_id"])
    else:
        item = selected(q, args.trend_id)
    if int(item.get("attempts", 0)) >= 3:
        raise RuntimeError("Max attempts reached: no send")
    if not args.run:
        print("TT_V2_PREFLIGHT=YES")
        print("TT_V2_TREND=" + item["name"])
        print("TT_V2_REVISION=" + str(item["revision"]))
        print("TT_V2_MESSAGE_SENT=NO")
        print("TT_V2_GITHUB_WRITE=NO")
        return
    try:
        run_one(api, state, transcript, auth, item)
    except Exception as exc:
        print("TT_V2_RUN_ERROR=" + str(exc), file=sys.stderr, flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
