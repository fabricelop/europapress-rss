#!/usr/bin/env python3
"""V2: un único envío editorial ChatGPT mediante Chrome nativo + CDP.

Sin escrituras en GitHub ni publicaciones. No reintenta envíos ni elude retos.
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
CHROME = pathlib.Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Google" / "Chrome" / "Application" / "chrome.exe"
OUT = ROOT / "diagnostics" / "one-editorial-cdp.json"
QUEUE_URL = "https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttendencias/state/editorial-queue.json"
TREND_ID = "trv2-dd5de9a892ab6b7007ef26b6"
COMPOSERS = ("#prompt-textarea", "[data-testid='prompt-textarea']", "[contenteditable='true'][role='textbox']")

def fetch_json(url):
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.load(response)

def find_visible(page, selectors):
    for selector in selectors:
        loc = page.locator(selector).first
        if loc.count() and loc.is_visible() and loc.is_enabled():
            return loc
    return None

def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    queue = fetch_json(QUEUE_URL)
    job = queue["items"].get(TREND_ID)
    if not job or job.get("revision") != 1 or job.get("status") != "pending":
        raise RuntimeError("La tendencia ya no esta pendiente en revision 1. No enviar.")
    if not CHROME.exists():
        raise RuntimeError("Chrome no encontrado")
    prompt = (
        "TTActualidad V2. PRUEBA EDITORIAL REAL, NO PUBLICAR NI MODIFICAR GITHUB. "
        "Explica por que es tendencia en Espana hoy " + job["name"] + ". "
        "Investiga y contrasta la actualidad con fuentes fiables; no presupongas el motivo. "
        "Si no puedes verificarlo, indicalo expresamente. "
        "Redacta una explicacion periodistica breve, hashtags pertinentes y un unico remate "
        "con humor suave solo si resulta oportuno. Adjunta enlaces a las fuentes y la fecha. "
        "Identificador " + TREND_ID + ", revision 1."
    )
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    result = {"trend_id": TREND_ID, "revision": 1, "name": job["name"],
              "message_sent": False, "reply_captured": False, "queue_modified": False,
              "published": False, "status": "not_started"}
    proc = None
    browser = None
    try:
        proc = subprocess.Popen([
            str(CHROME), f"--user-data-dir={PROFILE}",
            f"--remote-debugging-port={port}", "--remote-debugging-address=127.0.0.1",
            "--disable-extensions", "--no-first-run", "--no-default-browser-check",
            "--new-window", "https://chatgpt.com/"
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        endpoint = f"http://127.0.0.1:{port}"
        for _ in range(35):
            try:
                fetch_json(endpoint + "/json/version")
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("Chrome CDP no disponible")
        print("TT_V2_CDP_CONNECTED=YES", flush=True)
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint, timeout=15000)
            context = browser.contexts[0]
            page = next((p for p in context.pages if "chatgpt.com" in p.url), None)
            if page is None:
                page = context.new_page()
                page.goto("https://chatgpt.com/", wait_until="domcontentloaded", timeout=45000)
            deadline = time.monotonic() + 100
            composer = None
            while time.monotonic() < deadline:
                composer = find_visible(page, COMPOSERS)
                if composer is not None:
                    break
                time.sleep(2)
            if composer is None:
                raise RuntimeError("Editor no disponible; sin envio")
            print("TT_V2_COMPOSER_READY=YES", flush=True)
            # Nuevo chat para no tocar ninguna conversación existente.
            # El usuario debe disponer de ChatGPT en el inicio; URL comprobada.
            if not page.url.startswith("https://chatgpt.com/"):
                raise RuntimeError("Pagina inesperada; sin envio")
            before = page.locator("[data-message-author-role='assistant']").count()
            composer.fill(prompt)
            print("TT_V2_PROMPT_FILLED=YES", flush=True)
            # Solo pulsar Enter una vez; no reintentar ante fallos de confirmación.
            composer.press("Enter")
            result["message_sent"] = True
            result["status"] = "sent_waiting_for_answer"
            result["sent_at"] = datetime.now(timezone.utc).isoformat()
            print("TT_V2_MESSAGE_SENT_ONCE=YES", flush=True)
            end = time.monotonic() + 150
            latest = ""
            stable = 0
            while time.monotonic() < end:
                messages = page.locator("[data-message-author-role='assistant']")
                if messages.count() > before:
                    current = messages.last.inner_text(timeout=3000).strip()
                    if current and current == latest:
                        stable += 1
                    else:
                        latest = current
                        stable = 0
                    # Stability alone does not certify completion. Require stop button gone.
                    stop = page.locator("[data-testid='stop-button'],button[aria-label*='Stop'],button[aria-label*='Detener']")
                    if latest and stable >= 4 and stop.count() == 0:
                        result["reply_captured"] = True
                        result["answer"] = latest
                        result["status"] = "captured_unverified"
                        break
                time.sleep(2)
            result["chat_url"] = page.url
            if result["reply_captured"]:
                print("TT_V2_REPLY_CAPTURED=YES", flush=True)
                print("TT_V2_REPLY_CHARS=" + str(len(result["answer"])), flush=True)
            else:
                print("TT_V2_REPLY_CAPTURED=NO", flush=True)
                print("TT_V2_REPLY_STATUS=NOT_VERIFIED", flush=True)
    except Exception as exc:
        result["error"] = str(exc)[:500]
        print("TT_V2_ERROR=" + result["error"], flush=True)
    finally:
        if browser:
            try:
                browser.close()
            except Exception:
                pass
        if proc:
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                               capture_output=True, timeout=15)
            print("TT_V2_CHROME_LAUNCHER_EXITED=" + str(proc.poll() is not None), flush=True)
        OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("TT_V2_DIAGNOSTIC=" + str(OUT), flush=True)
        print("TT_V2_GITHUB_WRITE=NO", flush=True)
        print("TT_V2_PUBLISHED=NO", flush=True)

if __name__ == "__main__":
    main()
