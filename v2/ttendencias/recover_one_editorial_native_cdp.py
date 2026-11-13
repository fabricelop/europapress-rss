#!/usr/bin/env python3
"""TTActualidad V2: recuperar una respuesta YA enviada, sin enviar mensajes.

Solo inspecciona la conversación existente. No modifica GitHub ni publica.
Windows: Chrome nativo aislado + conexión Playwright por CDP.
"""
import json
import os
import pathlib
import socket
import subprocess
import time
import urllib.request
from datetime import datetime, timezone

from playwright.sync_api import sync_playwright
import re

# Copia autónoma del extractor: este recuperador se descarga como un único archivo.
PROMPT_MARKER = "You said:"
ASSISTANT_MARKER = "ChatGPT said:"
END_MARKERS = ("ChatGPT can make mistakes.", "Latest response")


def extract_reply(transcript: str, *, trend_id: str, revision: int):
    """Devuelve (texto, diagnóstico). Fail-closed ante conversación ambigua."""
    if not isinstance(transcript, str) or not transcript.strip():
        return "", "empty_document"
    # Solo considerar turnos del diálogo, nunca coincidencias aisladas del menú.
    user_pos = transcript.rfind("\n" + PROMPT_MARKER + "\n")
    if user_pos < 0:
        return "", "user_turn_not_found"
    following = transcript[user_pos + len(PROMPT_MARKER) + 2:]
    assistant_pos = following.find("\n" + ASSISTANT_MARKER + "\n")
    if assistant_pos < 0:
        return "", "assistant_turn_not_found"
    prompt = following[:assistant_pos]
    expected_revision = rf"\brevisi[oó]n\s*[: ]\s*{revision}\b"
    if trend_id not in prompt or not re.search(expected_revision, prompt, re.I):
        return "", "prompt_identity_mismatch"
    remainder = following[assistant_pos + len(ASSISTANT_MARKER) + 2:]
    if "\n" + PROMPT_MARKER + "\n" in remainder:
        return "", "multiple_turns_after_target"
    cuts = [remainder.find(m) for m in END_MARKERS if m in remainder]
    if not cuts:
        return "", "completion_footer_missing"
    response = remainder[:min(cuts)].strip()
    if len(response) < 80:
        return "", "short_response"
    # La respuesta puede no repetir el ID: la identidad proviene del turno
    # de usuario enlazado, no de una coincidencia accidental en la respuesta.
    return response, "visible_transcript_bound_to_prompt_and_footer"


ROOT = pathlib.Path(os.environ["LOCALAPPDATA"]) / "TTActualidadV2"
PROFILE = ROOT / "ChromeProfile"
OUT = ROOT / "diagnostics" / "recover-svfinal-cdp.json"
CHROME = pathlib.Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Google" / "Chrome" / "Application" / "chrome.exe"
CHAT_URL = "https://chatgpt.com/c/6af6bf87-b004-83eb-acae-47268afcef15"
TREND_ID = "trv2-dd5de9a892ab6b7007ef26b6"
REVISION = 1
ASSISTANT_SELECTORS = (
    "[data-message-author-role='assistant']",
    "[data-testid^='conversation-turn-'] [data-message-author-role='assistant']",
    "article[data-turn='assistant']",
    "[data-testid='assistant-message']",
)
STOP_SELECTOR = "[data-testid='stop-button'],button[aria-label*='Stop'],button[aria-label*='Detener']"
READY_CONTROLS = (
    "button[data-testid='copy-turn-action-button'],"
    "button[aria-label*='Copy'],button[aria-label*='Copiar'],"
    "button[data-testid='regenerate-response-button']"
)

def matching_profile_pids():
    """No inspeccionar ni terminar procesos de Chrome ajenos al perfil exacto."""
    ps = (
        "$p=$env:LOCALAPPDATA+'\\TTActualidadV2\\ChromeProfile';"
        "Get-CimInstance Win32_Process -Filter \"Name = 'chrome.exe'\" | "
        "Where-Object { $_.CommandLine -and $_.CommandLine.Contains('--user-data-dir=') "
        "-and $_.CommandLine.Contains($p) } | "
        "Select-Object -ExpandProperty ProcessId | ConvertTo-Json -Compress"
    )
    p = subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps],
                       capture_output=True, text=True, timeout=20)
    if p.returncode:
        raise RuntimeError("No se pudo inspeccionar procesos V2: " + p.stderr[-300:])
    raw = p.stdout.strip()
    if not raw:
        return []
    data = json.loads(raw)
    return [int(x) for x in (data if isinstance(data, list) else [data])]

def fetch_version(endpoint):
    with urllib.request.urlopen(endpoint + "/json/version", timeout=3) as response:
        return json.load(response)

def snapshot(page):
    return page.evaluate("""() => ({
      url: location.href,
      title: document.title,
      roles: [...document.querySelectorAll('[data-message-author-role]')]
        .map(x => ({role:x.getAttribute('data-message-author-role'),chars:(x.innerText||'').length})).slice(-12),
      readyState: document.readyState,
      bodyLength: (document.body?.innerText || '').length,
      bodyPreview: (document.body?.innerText || '').slice(0, 3500),
      bodyHtmlPreview: (document.body?.innerHTML || '').slice(0, 1500),
      frames: [...document.querySelectorAll('iframe')].map(x=>({src:x.src, title:x.title})).slice(0,10),
      domCounts: {articles:document.querySelectorAll('article').length,
        main:document.querySelectorAll('main').length,
        markdown:document.querySelectorAll('.markdown').length,
        shadowHosts:[...document.querySelectorAll('*')].filter(x=>x.shadowRoot).length},
      testids: [...document.querySelectorAll('[data-testid]')]
        .map(x=>x.getAttribute('data-testid')).slice(-50)
    })""")

def collect_assistant(page):
    for selector in ASSISTANT_SELECTORS:
        loc = page.locator(selector)
        if loc.count():
            texts = [s.strip() for s in loc.all_inner_texts() if s.strip()]
            if texts:
                return selector, texts[-1]
    return None, ""

def collect_from_visible_transcript(page):
    body = page.locator("body").inner_text(timeout=7000)
    answer, status = extract_reply(body, trend_id=TREND_ID, revision=REVISION)
    return ("body-transcript/paired-turns" if answer else None), answer


def validates_existing_reply(page, answer, selector):
    """Validación conservadora: no declarar captura si falta el final."""
    if page.url != CHAT_URL or not answer:
        return False
    if TREND_ID not in answer or "Revisión: 1" not in answer:
        return False
    if "Explicación editorial" not in answer or "#SVFinal" not in answer:
        return False
    if "Fuentes consultadas:" not in answer:
        return False
    # En esta conversación histórica, el remate de fin es conocido y
    # demuestra que no hemos extraído una respuesta parcial.
    if "No se ha publicado contenido ni modificado GitHub." not in answer:
        return False
    if selector == "body-transcript/paired-turns":
        return "ChatGPT can make mistakes." in page.locator("body").inner_text()
    return True


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    result = {"trend_id": TREND_ID, "revision": REVISION, "chat_url": CHAT_URL,
              "message_sent": False, "reply_captured": False, "queue_modified": False,
              "published": False, "status": "not_started",
              "observed_at": datetime.now(timezone.utc).isoformat()}
    proc = None
    browser = None
    owned_pids = set()
    launched = False
    try:
        existing = matching_profile_pids()
        if existing:
            raise RuntimeError("Chrome V2 ya abierto; no lanzar otro proceso con el perfil: " + str(existing))
        if not CHROME.exists():
            raise RuntimeError("Chrome nativo no encontrado")
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        proc = subprocess.Popen([
            str(CHROME), f"--user-data-dir={PROFILE}",
            f"--remote-debugging-port={port}", "--remote-debugging-address=127.0.0.1",
            "--disable-extensions", "--no-first-run", "--no-default-browser-check",
            "--new-window", CHAT_URL
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        launched = True
        endpoint = f"http://127.0.0.1:{port}"
        for _ in range(40):
            try:
                fetch_version(endpoint)
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("CDP no disponible")
        owned_pids = set(matching_profile_pids())
        if not owned_pids:
            raise RuntimeError("No se pudo identificar el Chrome V2 lanzado; se aborta sin limpieza ajena")
        print("TT_V2_CDP_CONNECTED=YES", flush=True)
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint)
            context = browser.contexts[0]
            page = next((p for p in context.pages if "/c/6af6bf87-" in p.url), None)
            if page is None:
                page = context.new_page()
                page.goto(CHAT_URL, wait_until="domcontentloaded", timeout=60000)
            deadline = time.monotonic() + 50
            previous = ""
            stable = 0
            observations = []
            while time.monotonic() < deadline:
                if not page.url.startswith(CHAT_URL):
                    time.sleep(2)
                    continue
                selector, answer = collect_assistant(page)
                if not answer:
                    selector, answer = collect_from_visible_transcript(page)
                stop = page.locator(STOP_SELECTOR).count() > 0
                ready_control = page.locator(READY_CONTROLS).count() > 0
                observations.append({"chars": len(answer), "selector": selector,
                                     "stop": stop, "ready_control": ready_control})
                if answer and answer == previous:
                    stable += 1
                else:
                    previous, stable = answer, 0
                # La estabilidad NO basta: exigir control de acciones de respuesta
                # terminada y ausencia de control de parada.
                if answer and stable >= 3 and not stop and len(answer) >= 80 and (ready_control or selector == "body-transcript/paired-turns") and validates_existing_reply(page, answer, selector):
                    result["answer"] = answer
                    result["reply_captured"] = True
                    result["status"] = "captured_needs_editorial_validation"
                    result["selector"] = selector
                    result["validation"] = "paired_turn_id_revision_footer_and_stable_idle"
                    break
                time.sleep(2)
            result["observations"] = observations[-20:]
            result["dom"] = snapshot(page)
            result["frames"] = [{"url": f.url, "name": f.name} for f in page.frames]
            result["page_count"] = len(context.pages)
            result["page_urls"] = [p.url for p in context.pages]
            # Los diagnósticos se guardan localmente; no se envían a GitHub.
            if not result["reply_captured"]:
                try:
                    shot = OUT.with_suffix(".png")
                    page.screenshot(path=str(shot), full_page=False, timeout=10000)
                    result["screenshot"] = str(shot)
                except Exception as exc:
                    result["screenshot_error"] = str(exc)[:200]
            if not result["reply_captured"]:
                result["status"] = "not_verified"
                result["last_visible_answer"] = previous[:12000]
                result["last_selector"] = selector
            print("TT_V2_REPLY_CAPTURED=" + ("YES" if result["reply_captured"] else "NO"), flush=True)
            print("TT_V2_REPLY_STATUS=" + result["status"], flush=True)
            if result["reply_captured"]:
                print("TT_V2_REPLY_CHARS=" + str(len(result["answer"])), flush=True)
            try:
                # Cerrar el navegador completo por CDP, no solo la conexión.
                session = browser.new_browser_cdp_session()
                session.send("Browser.close")
            except Exception as exc:
                result["browser_close_error"] = str(exc)[:250]
    except Exception as exc:
        result["error"] = str(exc)[:500]
        result["status"] = "error"
        print("TT_V2_ERROR=" + result["error"], flush=True)
    finally:
        if browser:
            try:
                browser.close()
            except Exception:
                pass
        if proc:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        try:
            remaining = matching_profile_pids()
            # NO terminar procesos anteriores a la ejecución ni desconocidos.
            # Si no se confirmó propiedad, solamente registrar la incidencia.
            targets = sorted(set(remaining) & owned_pids)
            for pid in targets:
                subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                               capture_output=True, timeout=15)
            if targets:
                time.sleep(2)
            remaining = matching_profile_pids()
            result["remaining_v2_pids"] = remaining
            result["cleanup_verified"] = not remaining and launched
            if remaining:
                result["cleanup_warning"] = "Quedan procesos V2; no se terminan procesos no identificados como propios"
            print("TT_V2_REMAINING_PROCESSES=" + str(len(remaining)), flush=True)
        except Exception as exc:
            result["cleanup_error"] = str(exc)[:500]
            print("TT_V2_CLEANUP_VERIFIED=NO", flush=True)
        OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("TT_V2_DIAGNOSTIC=" + str(OUT), flush=True)
        print("TT_V2_GITHUB_WRITE=NO", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)

if __name__ == "__main__":
    main()
