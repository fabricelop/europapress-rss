#!/usr/bin/env python3
"""V2: Chrome normal + CDP separado (como V1). Solo diagnóstico; no envía mensajes."""
import json, os, pathlib, socket, subprocess, time, urllib.request, urllib.error
from playwright.sync_api import sync_playwright

ROOT=pathlib.Path(os.environ["LOCALAPPDATA"])/"TTActualidadV2"
PROFILE=ROOT/"ChromeProfile"
OUT=ROOT/"diagnostics"/"native-cdp.json"
CHROME=pathlib.Path(os.environ.get("PROGRAMFILES",r"C:\Program Files"))/"Google"/"Chrome"/"Application"/"chrome.exe"
SELECTORS=("#prompt-textarea","[data-testid='prompt-textarea']","[contenteditable='true'][role='textbox']","[contenteditable='true']","textarea")

def check_port(port):
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1",port))==0

def main():
    OUT.parent.mkdir(parents=True,exist_ok=True)
    if not CHROME.exists():
        raise RuntimeError("Chrome no encontrado: "+str(CHROME))
    # Un puerto aleatorio, reservado por Chrome al iniciar, separado de 9223/9234.
    # La instancia no debe estar ya abierta para este perfil.
    with socket.socket() as s:
        s.bind(("127.0.0.1",0))
        port=s.getsockname()[1]
    if port in (9223,9234):
        raise RuntimeError("Puerto reservado de V1")
    result={"ready":False,"challenge_seen":False,"sent":False,"port":port,"error":None}
    proc=None
    browser=None
    try:
        cmd=[str(CHROME),f"--user-data-dir={PROFILE}",f"--remote-debugging-port={port}",
             "--remote-debugging-address=127.0.0.1","--disable-extensions",
             "--no-first-run","--no-default-browser-check","--new-window",
             "https://chatgpt.com/"]
        print("TT_V2_NATIVE_CHROME_START=YES",flush=True)
        proc=subprocess.Popen(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        endpoint=f"http://127.0.0.1:{port}"
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            try:
                with urllib.request.urlopen(endpoint+"/json/version",timeout=2) as r:
                    info=json.load(r)
                break
            except (OSError,ValueError):
                time.sleep(1)
        else:
            raise RuntimeError("CDP no respondió: perfil ocupado o Chrome bloqueado")
        print("TT_V2_CDP_CONNECTED=YES",flush=True)
        with sync_playwright() as pw:
            browser=pw.chromium.connect_over_cdp(endpoint,timeout=15000)
            ctx=browser.contexts[0]
            page=next((p for p in ctx.pages if "chatgpt.com" in p.url),None)
            if page is None:
                page=ctx.new_page()
                page.goto("https://chatgpt.com/",wait_until="domcontentloaded",timeout=45000)
            deadline=time.monotonic()+90
            last_title=""
            while time.monotonic()<deadline:
                try:
                    title=page.title()
                    if title!=last_title:
                        print("TT_V2_TITLE="+title,flush=True)
                        last_title=title
                    if "just a moment" in title.lower():
                        result["challenge_seen"]=True
                    for selector in SELECTORS:
                        el=page.locator(selector).first
                        if el.count() and el.is_visible() and el.is_enabled():
                            result.update({"ready":True,"selector":selector})
                            break
                    if result["ready"]:
                        break
                except Exception as exc:
                    result["last_check_error"]=str(exc)[:160]
                time.sleep(2)
            result["url"]=page.url
            result["title"]=page.title()
            print("TT_V2_READY_UNATTENDED="+("YES" if result["ready"] else "NO"),flush=True)
            print("TT_V2_CHALLENGE_SEEN="+("YES" if result["challenge_seen"] else "NO"),flush=True)
    except Exception as exc:
        result["error"]=str(exc)[:400]
        print("TT_V2_ERROR="+result["error"],flush=True)
    finally:
        # CDP Browser.close cierra SOLO la instancia de V2, nunca V1.
        if browser:
            try:
                browser.close()
                print("TT_V2_CDP_CLOSE_REQUESTED=YES",flush=True)
            except Exception:
                pass
        if proc:
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                # Solo PID iniciado por esta prueba, nunca procesos de V1.
                subprocess.run(["taskkill","/PID",str(proc.pid),"/T","/F"],
                               capture_output=True,timeout=15)
            print("TT_V2_CHROME_LAUNCHER_EXITED="+str(proc.poll() is not None),flush=True)
        OUT.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        print("TT_V2_NO_MESSAGE_SENT=YES",flush=True)
        print("TT_V2_DIAGNOSTIC="+str(OUT),flush=True)

if __name__=="__main__":
    main()
