#!/usr/bin/env python3
"""V2: prueba de disponibilidad de ChatGPT tras verificaciones, sin intervención manual.

No intenta superar desafíos ni escribir mensajes. Solo observa si la sesión
autenticada presenta el editor de ChatGPT sin intervención del usuario.
"""
import argparse
import json
import os
from pathlib import Path
import time
from playwright.sync_api import sync_playwright

PROFILE = Path(os.environ["LOCALAPPDATA"]) / "TTActualidadV2" / "ChromeProfile"
CHROME = Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Google" / "Chrome" / "Application" / "chrome.exe"
SELECTORS = (
    "#prompt-textarea",
    "[data-testid='prompt-textarea']",
    "[contenteditable='true'][role='textbox']",
    "[contenteditable='true']",
    "textarea",
)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--seconds",type=int,default=120)
    args=parser.parse_args()
    if not 10 <= args.seconds <= 300:
        parser.error("--seconds debe ser entre 10 y 300")
    output=Path(os.environ["LOCALAPPDATA"])/"TTActualidadV2"/"diagnostics"/"unattended-browser.json"
    output.parent.mkdir(parents=True,exist_ok=True)
    result={"ready":False,"intervention":False,"challenge_seen":False,"sent":False,"error":None}
    ctx=None
    with sync_playwright() as pw:
        try:
            ctx=pw.chromium.launch_persistent_context(
                str(PROFILE),executable_path=str(CHROME),headless=False,
                args=["--disable-extensions","--no-first-run","--no-default-browser-check"],
                viewport={"width":1200,"height":900},timeout=30000)
            page=ctx.pages[0] if ctx.pages else ctx.new_page()
            page.goto("https://chatgpt.com/",wait_until="domcontentloaded",timeout=45000)
            deadline=time.monotonic()+args.seconds
            last_title=None
            while time.monotonic()<deadline:
                title=page.title()
                if title!=last_title:
                    print("TT_V2_PAGE_TITLE="+title,flush=True)
                    last_title=title
                if title.strip().lower()=="just a moment...":
                    result["challenge_seen"]=True
                for selector in SELECTORS:
                    locator=page.locator(selector).first
                    if locator.count() and locator.is_visible() and locator.is_enabled():
                        result.update({"ready":True,"selector":selector})
                        print("TT_V2_COMPOSER_READY=YES",flush=True)
                        break
                if result["ready"]:
                    break
                page.wait_for_timeout(2000)
            result["url"]=page.url
            result["title"]=page.title()
            print("TT_V2_READY_UNATTENDED="+("YES" if result["ready"] else "NO"),flush=True)
            print("TT_V2_CHALLENGE_SEEN="+("YES" if result["challenge_seen"] else "NO"),flush=True)
        except Exception as exc:
            result["error"]=str(exc)[:400]
            print("TT_V2_ERROR="+result["error"],flush=True)
        finally:
            if ctx:
                ctx.close()
                print("TT_V2_BROWSER_CLOSE_REQUESTED",flush=True)
            output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
            print("TT_V2_RESULT_FILE="+str(output),flush=True)
            print("TT_V2_MESSAGE_SENT=NO",flush=True)
if __name__=="__main__":
    main()
