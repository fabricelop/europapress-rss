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
      testids: [...document.querySelectorAll('[data-testid]')]
        .map(x=>x.getAttribute('data-testid')).filter(x=>/message|turn|stop|copy|regenerat/i.test(x)).slice(-35)
    })""")

def collect_assistant(page):
    for selector in ASSISTANT_SELECTORS:
        loc = page.locator(selector)
        if loc.count():
            texts = [s.strip() for s in loc.all_inner_texts() if s.strip()]
            if texts:
                return selector, texts[-1]
    return None, ""

def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    result = {"trend_id": TREND_ID, "revision": REVISION, "chat_url": CHAT_URL,
              "message_sent": False, "reply_captured": False, "queue_modified": False,
              "published": False, "status": "not_started",
              "observed_at": datetime.now(timezone.utc).isoformat()}
    proc = None
    browser = None
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
        endpoint = f"http://127.0.0.1:{port}"
        for _ in range(40):
            try:
                fetch_version(endpoint)
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("CDP no disponible")
        print("TT_V2_CDP_CONNECTED=YES", flush=True)
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint)
            context = browser.contexts[0]
            page = next((p for p in context.pages if "/c/6af6bf87-" in p.url), None)
            if page is None:
                page = context.new_page()
                page.goto(CHAT_URL, wait_until="domcontentloaded", timeout=60000)
            deadline = time.monotonic() + 150
            previous = ""
            stable = 0
            observations = []
            while time.monotonic() < deadline:
                if not page.url.startswith(CHAT_URL):
                    time.sleep(2)
                    continue
                selector, answer = collect_assistant(page)
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
                if answer and stable >= 3 and not stop and ready_control:
                    result["answer"] = answer
                    result["reply_captured"] = True
                    result["status"] = "captured_needs_editorial_validation"
                    result["selector"] = selector
                    break
                time.sleep(2)
            result["observations"] = observations[-20:]
            result["dom"] = snapshot(page)
            if not result["reply_captured"]:
                result["status"] = "not_verified"
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
            for pid in remaining:
                subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                               capture_output=True, timeout=15)
            time.sleep(2)
            remaining = matching_profile_pids()
            result["remaining_v2_pids"] = remaining
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
