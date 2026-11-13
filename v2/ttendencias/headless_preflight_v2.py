#!/usr/bin/env python3
"""Safe headless Chrome V2 preflight: open authenticated composer, send nothing.

Must run only while the V2 daemon is stopped and ChromeProfile not in use.
Never closes a browser it did not start. No V1 changes.
"""
import json
import socket
import subprocess
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright
import editorial_run_v2 as core
from chrome_command_v2 import command


def verify():
    if core.profile_pids():
        raise RuntimeError("Chrome V2 en uso: prueba oculta bloqueada")
    if not core.CHROME.is_file() or not core.PROFILE.is_dir():
        raise RuntimeError("Chrome o perfil V2 inexistente")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    args = command(core.CHROME, core.PROFILE, port, headless=True)
    proc = None
    browser = None
    owned = set()
    success = False
    try:
        proc = subprocess.Popen(args,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        endpoint = "http://127.0.0.1:" + str(port)
        for _ in range(35):
            if proc.poll() is not None:
                raise RuntimeError("Chrome V2 oculto terminó antes de CDP")
            try:
                with urllib.request.urlopen(endpoint + "/json/version", timeout=2) as resp:
                    if json.load(resp).get("Browser"):
                        break
            except (OSError, ValueError):
                time.sleep(1)
        else:
            raise RuntimeError("No se pudo conectar al CDP V2 oculto")
        owned = core.profile_pids()
        if not owned:
            raise RuntimeError("No se identificó proceso Chrome V2 de prueba")
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint, timeout=18000)
            if not browser.contexts:
                raise RuntimeError("Chrome V2 no tiene contexto de usuario")
            context = browser.contexts[0]
            page = next((p for p in context.pages if p.url.startswith("https://chatgpt.com/")), None)
            if page is None:
                page = context.new_page()
                page.goto("https://chatgpt.com/", wait_until="domcontentloaded", timeout=45000)
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if page.url.startswith("https://chatgpt.com/"):
                    for selector in core.COMPOSERS:
                        field = page.locator(selector).first
                        if field.count() and field.is_visible() and field.is_enabled():
                            success = True
                            print("TT_V2_HEADLESS_CDP=YES", flush=True)
                            print("TT_V2_HEADLESS_COMPOSER_READY=YES", flush=True)
                            break
                if success:
                    break
                time.sleep(2)
            if not success:
                raise RuntimeError("ChatGPT V2 no presenta editor usable en Chrome oculto")
    finally:
        if browser:
            try:
                browser.new_browser_cdp_session().send("Browser.close")
            except Exception:
                pass
            try:
                browser.close()
            except Exception:
                pass
        if proc:
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                pass
        remaining = core.profile_pids()
        for pid in remaining & owned:
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True, timeout=15,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if proc and proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass
        time.sleep(1)
        if core.profile_pids():
            raise RuntimeError("Quedan procesos Chrome V2 tras prueba headless")
    print("TT_V2_HEADLESS_PROCESSES_CLOSED=YES", flush=True)
    print("TT_V2_HEADLESS_MESSAGE_SENT=NO", flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)


if __name__ == "__main__":
    try:
        verify()
    except Exception as exc:
        print("TT_V2_HEADLESS_PREFLIGHT_ERROR=" + str(exc), file=sys.stderr, flush=True)
        print("TT_V2_HEADLESS_MESSAGE_SENT=NO", flush=True)
        sys.exit(1)
