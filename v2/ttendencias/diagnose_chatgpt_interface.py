"""Diagnostico de interfaz ChatGPT en V2. SOLO lectura, sin enviar prompts."""
import json
import os
import pathlib
import time
from playwright.sync_api import sync_playwright

profile=pathlib.Path(os.environ["LOCALAPPDATA"])/"TTActualidadV2"/"ChromeProfile"
out=pathlib.Path(os.environ["LOCALAPPDATA"])/"TTActualidadV2"/"diagnostics"
out.mkdir(parents=True,exist_ok=True)
chrome=pathlib.Path(os.environ.get("PROGRAMFILES",r"C:\Program Files"))/"Google"/"Chrome"/"Application"/"chrome.exe"
with sync_playwright() as p:
    context=None
    try:
        context=p.chromium.launch_persistent_context(str(profile),executable_path=str(chrome),headless=False,
            args=["--disable-extensions","--no-first-run","--no-default-browser-check"],
            viewport={"width":1200,"height":900})
        page=context.pages[0] if context.pages else context.new_page()
        page.goto("https://chatgpt.com/",wait_until="domcontentloaded",timeout=45000)
        page.wait_for_timeout(12000)
        selectors=[
            "#prompt-textarea",
            "[data-testid='prompt-textarea']",
            "[contenteditable='true']",
            "[role='textbox']",
            "textarea",
            "iframe",
        ]
        results={selector:page.locator(selector).count() for selector in selectors}
        details=page.evaluate("""() => [...document.querySelectorAll('[contenteditable],textarea,[role="textbox"]')].map(el=>({
            tag:el.tagName, id:el.id, role:el.getAttribute('role'),
            testid:el.getAttribute('data-testid'),
            placeholder:el.getAttribute('placeholder'),
            ariaLabel:el.getAttribute('aria-label'),
            visible:!!(el.offsetWidth||el.offsetHeight||el.getClientRects().length)
        })).slice(0,20)""")
        data={"url":page.url,"title":page.title(),"selectors":results,"editables":details,
              "pages":[{"url":x.url,"title":x.title()} for x in context.pages]}
        dest=out/"chatgpt-interface.json"
        dest.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding="utf-8")
        print("TT_V2_DIAGNOSTIC="+str(dest))
        print(json.dumps(data,ensure_ascii=False,indent=2))
        print("TT_V2_NO_PROMPT_SENT=YES")
    finally:
        if context:
            context.close()
            print("TT_V2_BROWSER_CLOSE_REQUESTED")
