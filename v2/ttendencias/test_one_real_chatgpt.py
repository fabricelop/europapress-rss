"""V2 5B: una elaboración real en ChatGPT, aislada y SIN guardar en GitHub.

Requiere pip install playwright. Solo selecciona un ID pendiente fijo.
No modifica la cola, no publica y cierra siempre su navegador.
"""
import argparse
import json
import os
import pathlib
import sys
import time
import urllib.request
from datetime import datetime, timezone
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

BRANCH = "feature/ttactualidad-v2-clean"
QUEUE_URL = "https://raw.githubusercontent.com/fabricelop/europapress-rss/" + BRANCH + "/v2/ttendencias/state/editorial-queue.json"
ID = "trv2-dd5de9a892ab6b7007ef26b6"
PROFILE = pathlib.Path(os.environ["LOCALAPPDATA"]) / "TTActualidadV2" / "ChromeProfile"
OUTPUT = pathlib.Path(os.environ["LOCALAPPDATA"]) / "TTActualidadV2" / "test-output"
CHROME = pathlib.Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Google" / "Chrome" / "Application" / "chrome.exe"

def get_queue():
    with urllib.request.urlopen(QUEUE_URL, timeout=20) as response:
        return json.load(response)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--send", action="store_true", help="Envia UN prompt a ChatGPT; sin --send solo comprueba la cola")
    args = parser.parse_args()
    queue = get_queue()
    item = queue["items"].get(ID)
    if not item or item["status"] != "pending" or item["revision"] != 1:
        raise RuntimeError("El ID ya no esta pendiente en revision 1: cancelar")
    print("TT_V2_JOB", item["trend_id"], item["name"], "revision", item["revision"])
    if not args.send:
        print("TT_V2_DRY_RUN: sin navegador, sin mensaje, sin escrituras")
        return
    prompt = (
        "PRUEBA EDITORIAL TTActualidad V2, NO PUBLICAR. Investiga con fuentes fiables y actuales "
        "por que es tendencia en Espana el termino " + item["name"] + ". "
        "Si no puedes confirmar el motivo, dilo claramente. Responde con un texto breve en espanol, "
        "fecha y enlaces a las fuentes. No accedas a GitHub ni modifiques ninguna cola o repositorio. "
        "Identificador de prueba " + ID + " revision 1."
    )
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        context = None
        try:
            context = playwright.chromium.launch_persistent_context(
                str(PROFILE), executable_path=str(CHROME), headless=False,
                args=["--disable-extensions", "--no-first-run", "--no-default-browser-check"],
                viewport={"width":1200,"height":900}, timeout=30000,
            )
            page = context.new_page()
            page.goto("https://chatgpt.com/", wait_until="domcontentloaded", timeout=45000)
            print("TT_V2_BROWSER_OPENED")
            # Un selector verificable; si cambia la interfaz, cancelar SIN enviar.
            composer = page.locator('#prompt-textarea')
            composer.wait_for(state="visible", timeout=45000)
            composer.fill(prompt)
            print("TT_V2_PROMPT_FILLED")
            # Solo una interaccion de envio. No se reintenta automaticamente.
            composer.press("Enter")
            print("TT_V2_PROMPT_SENT_ONCE")
            # La interfaz es variable: no inferir completitud de un texto parcial.
            print("TT_V2_WAITING_FOR_MANUAL_REVIEW: revisa la respuesta en la ventana.")
            print("TT_V2_NO_GITHUB_WRITE: la cola permanece pending")
            page.wait_for_timeout(60000)
            snapshot = {
                "trend_id": ID, "revision": 1, "name": item["name"],
                "sent_at": datetime.now(timezone.utc).isoformat(),
                "chatgpt_url": page.url,
                "status": "manual_review_required",
                "queue_modified": False,
            }
            dest = OUTPUT / "first-editorial-test.json"
            dest.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8")
            print("TT_V2_LOCAL_DIAGNOSTIC=" + str(dest))
        finally:
            if context is not None:
                context.close()
                print("TT_V2_BROWSER_CLOSE_REQUESTED")
if __name__ == "__main__":
    main()
