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
# Chrome normal con ventana oculta conserva el comportamiento de autenticación
# de V2. El headless real queda reservado para diagnósticos explícitos.
HEADLESS = os.environ.get("TT_V2_CHROME_HEADLESS", "0").strip().lower() not in ("0", "false", "no")
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
                         capture_output=True, text=True, timeout=20,
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if run.returncode:
        raise RuntimeError("No se pudo inspeccionar Chrome V2")
    raw = run.stdout.strip()
    value = json.loads(raw) if raw else []
    return set(map(int, value if isinstance(value, list) else [value]))

def prompt_for(item):
    # Alineado con la investigación prudente de V1, pero sin reutilizar su
    # navegador, caché, sesión, tokens ni colas de producción.
    return (
        "TTActualidad V2. ELABORACIÓN EDITORIAL DE UNA SOLA TENDENCIA. "
        "NO PUBLICAR NI MODIFICAR GITHUB. Investiga por qué aparece entre las "
        "tendencias de España: " + item["name"] + ". "
        "Contrasta primero prensa, fuentes primarias y fechas de los hechos. "
        "SI NO ENCUENTRAS UN MOTIVO PREDOMINANTE RAZONABLEMENTE ACREDITADO, "
        "busca TAMBIÉN en X (x.com), revisando conversaciones recientes sobre "
        "el término literal y variantes relevantes. Indica enlaces canónicos "
        "https://x.com/usuario/status/ID y fechas de posts cuando los hayas "
        "podido consultar. Una conversación en X puede explicar de qué se "
        "habla, pero no demuestra por sí sola acusaciones ni causalidad; "
        "contrasta hechos con fuentes independientes. "
        "Si X es inaccesible, dilo claramente y NO finjas haber consultado "
        "publicaciones. NO reutilices explicaciones anteriores sin contrastar. "
        "Si después de buscar SIGUE SIN CONFIRMARSE el motivo, redacta de todos "
        "modos una ficha útil y prudente para LISTAS, explicando qué se sabe "
        "y qué no, sin adjudicar causas, personas o delitos sin pruebas. "
        "No bloquees la ficha solo por duda causal. Si ni siquiera es fiable "
        "la presencia de la tendencia, reconoce también ese límite. "
        "Da explicación periodística breve, hashtags pertinentes, un solo "
        "remate suave si procede y URLs HTTPS completas de fuentes reales. "
        "Incluye exactamente las líneas "
        "'ESTADO_CAUSA: CONFIRMADA' o 'ESTADO_CAUSA: NO_CONFIRMADA', "
        "y 'ESTADO_X: CONSULTADO' o 'ESTADO_X: INACCESIBLE' o "
        "'ESTADO_X: NO_NECESARIO'. En CONSULTADO, aporta las URL de posts "
        "realmente revisados; NO marques CONSULTADO por abrir un buscador "
        "sin poder leer posts. La ficha no autoriza publicación automática. "
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
        "expires_at": (now + timedelta(minutes=40)).isoformat()}
    queue_write(api, auth, sha, q, "claim " + trend_id)
    # La web muestra EN ELABORACIÓN antes de abrir la sesión individual.
    # Un fallo de proyección no provoca reenvío ni cambia la reserva.
    web = module("web_top30_v2.py", "ttv2_web_top30")
    try:
        snapshot = web.sync_to_github(auth)
        print("TT_V2_WEB_TOP30_CLAIM_SYNC=YES", flush=True)
    except Exception as exc:
        print("TT_V2_WEB_TOP30_CLAIM_SYNC=DEGRADED:" + type(exc).__name__, flush=True)
    record = {"trend_id": trend_id, "revision": revision, "lease_token": token,
              "message_sent": False, "reply_captured": False, "cleanup_verified": False,
              "queue_modified": True, "published": False,
              "status": "claimed", "observed_at": utcnow()}
    store(journal, record)
    proc = None
    browser = None
    hider = None
    owned = set()
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        if port in (9223, 9234):
            raise RuntimeError("Puerto de V1 reservado")
        chrome_builder = module("chrome_command_v2.py", "ttv2_chrome_command")
        chrome_args = chrome_builder.command(CHROME, PROFILE, port,
                                             headless=HEADLESS, hidden=not HEADLESS)
        visibility = module("chrome_visibility_v2.py", "ttv2_editorial_visibility")
        proc = subprocess.Popen(chrome_args,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            startupinfo=visibility.startupinfo_hidden() if not HEADLESS else None,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if not HEADLESS:
            hider = visibility.V2WindowHider(profile_pids).start()
        print("TT_V2_CHROME_MODE=" + ("HEADLESS" if HEADLESS else "HEADED_HIDDEN"), flush=True)
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
        if hider and hider.last_error:
            raise RuntimeError("No se pudo ocultar Chrome V2: " + hider.last_error)
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
            if hider and hider.last_error:
                raise RuntimeError("Chrome V2 no se puede mantener oculto; no enviar")
            # CRÍTICO: registrar intención en GitHub ANTES de pulsar Enter.
            # Si el proceso muere a continuación, NO puede reenviarse.
            # GitHub puede refrescar el Top30 entre la reserva y el envío.
            # Reintentar SOLO la intención (aún NO se ha pulsado Enter).
            for send_cas_attempt in range(4):
                q, sha = queue_read(api, auth)
                live = q["items"].get(trend_id, {})
                if (live.get("status") != "in_progress" or live.get("revision") != revision
                    or (live.get("lease") or {}).get("token") != token
                    or live.get("send_intent")):
                    raise RuntimeError("Reserva invalidada antes del envío")
                live["send_intent"] = {"token": token, "at": utcnow()}
                live["updated_at"] = utcnow()
                try:
                    queue_write(api, auth, sha, q, "send intent " + trend_id)
                    break
                except RuntimeError as exc:
                    if ("GitHub conflict/changed revision" not in str(exc)
                        or send_cas_attempt == 3):
                        raise
                    time.sleep(1 + send_cas_attempt)
            record["status"] = "send_intent_recorded"
            store(journal, record)
            tracker = module("chatgpt_target_tracker.py", "ttv2_target_tracker")
            baseline_conversations = tracker.conversation_urls(browser)
            composer.fill(prompt_for(item))
            composer.press("Enter")  # UNA sola pulsación. No reintentar.
            record["message_sent"] = True
            record["status"] = "sent_waiting_for_reply"
            store(journal, record)
            # Enumerar targets CDP: puede haber nuevas ventanas no asociadas
            # a la Page original. La URL solo se acepta tras validar prompt.
            matched, evidence = tracker.await_conversation(
                browser, page, trend_id, revision, seconds=90,
                baseline_urls=baseline_conversations)
            record["chat_discovery"] = evidence
            if matched is not None:
                page = matched
                record["chat_url"] = evidence["url"]
                print("TT_V2_CHAT_URL_RECORDED=YES", flush=True)
            else:
                print("TT_V2_CHAT_URL_RECORDED=NO", flush=True)
            store(journal, record)
            print("TT_V2_MESSAGE_SENT_ONCE=YES", flush=True)
            # Lectura sobre LA MISMA sesion, con una unica recarga del chat
            # si la pagina falla. Nunca repite el envio ni pulsa botones.
            if matched is None:
                capture = {"status": "no_verified_target", "answer": "",
                           "reason": "chat_target_identity_not_verified",
                           "reloads": 0, "url": page.url,
                           "observations": ["target_discovery_failed"]}
            else:
                capture = transcript.capture_existing_page(
                    page, trend_id=trend_id, revision=revision, seconds=900)
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
                    "validation": "paired_turn_id_revision_dom_or_footer_and_stable_idle"})
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
        if hider:
            hider.stop()
        if browser:
            try: browser.close()
            except Exception: pass
        if proc:
            try: proc.wait(timeout=7)
            except subprocess.TimeoutExpired:
                # Solo el proceso Chrome V2 que este mismo run_one abrió.
                try: proc.kill()
                except OSError: pass
        cleaner = module("chrome_cleanup_v2.py", "ttv2_editorial_chrome_cleanup")
        cleanup = cleaner.cleanup_v2_profile(profile_pids)
        remaining = cleanup["remaining"]
        record["remaining_v2_pids"] = remaining
        record["cleanup_verified"] = bool(proc) and cleanup["closed"]
        record["cleanup_rounds"] = cleanup["rounds"]
        store(journal, record)
        print("TT_V2_REMAINING_PROCESSES=" + str(len(remaining)), flush=True)
        print("TT_V2_CHROME_CLEANUP_ROUNDS=" + str(cleanup["rounds"]), flush=True)
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
    # El Top30 puede actualizarse cada 15 min y mover el SHA de la cola.
    # Releer/rebasar SOLO la persistencia tras cerrar Chrome; jamás reenviar.
    # stage_capture vuelve a verificar revisión, status y token del envío.
    for persist_attempt in range(4):
        fresh, sha = queue_read(api, auth)
        staged, status = state.stage_capture(fresh,
            trend_id=trend_id, revision=revision, answer=record["answer"],
            chat_url=record["chat_url"], validated_capture=True,
            observed_at=record["observed_at"], lease_token=token)
        if status == "already_staged":
            break
        try:
            queue_write(api, auth, sha, staged, "capture " + trend_id)
            break
        except RuntimeError as exc:
            if ("GitHub conflict/changed revision" not in str(exc)
                or persist_attempt == 3):
                raise
            time.sleep(1 + persist_attempt)
    # La confirmación real siempre es la relectura posterior.
    verify, queue_blob_sha = queue_read(api, auth)
    cap = verify["items"][trend_id].get("capture") or {}
    if (verify["items"][trend_id]["status"] != "captured_review"
        or cap.get("sha256") != hashlib.sha256(record["answer"].strip().encode()).hexdigest()
        or cap.get("editorial_validated") is not False):
        raise RuntimeError("Persistencia no verificada; no volver a enviar")
    record["status"] = "persisted_captured_review"
    record["persisted"] = True
    store(journal, record)
    print("TT_V2_GITHUB_VERIFIED=YES", flush=True)
    # Sin reenvío: incluir inmediatamente la ficha capturada en el modelo de
    # Listas V2, incluso si el motivo no está confirmado. No implica READY.
    listas = module("listas_v2.py", "ttv2_listas")
    projection = listas.sync_to_github(api, auth, verify, queue_blob_sha)
    card = projection["items"].get(trend_id)
    if (not card or card["revision"] != revision
        or card["capture_sha256"] != cap["sha256"]
        or card["publication_allowed"] is not False):
        raise RuntimeError("Listas V2 no refleja la captura; no avanzar lote")
    print("TT_V2_LISTAS_VERIFIED=YES", flush=True)
    print("TT_V2_LISTAS_CAUSE_STATUS=" + card["cause_status"], flush=True)
    # Reflejar la explicación capturada en Top30 web sin esperar al cron.
    web = module("web_top30_v2.py", "ttv2_web_top30")
    snapshot = web.sync_to_github(auth)
    current_top30 = next((entry for entry in snapshot["items"]
                          if entry["trend_id"] == trend_id), None)
    if current_top30 is not None:
        if (current_top30["revision"] != revision
            or current_top30["status"] != "explicada"
            or current_top30["explanation"] != cap["answer"]):
            raise RuntimeError("Top30 web V2 no refleja la explicación capturada")
    # Si salió del ranking, permanece capturada en GitHub y Listas V2.
    print("TT_V2_WEB_TOP30_VERIFIED=YES", flush=True)
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
        # Selección automática por puesto de un Top30 vigente. No recurrir
        # al backlog histórico solo porque es más antiguo.
        ranker = module("select_current_top30_v2.py", "ttv2_ranker")
        history = ranker.read_history(auth)
        eligible, age = ranker.select_current_top30(q, history, 1)
        print("TT_V2_SELECTION=CURRENT_TOP30_RANK_ORDER", flush=True)
        print("TT_V2_TOP30_AGE_MINUTES=" + str(age), flush=True)
        if not eligible:
            print("TT_V2_NO_ELIGIBLE_JOB=YES")
            return
        item = selected(q, eligible[0]["trend_id"])
    else:
        # Una selección explícita puede terminarse aunque haya salido del Top30.
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
