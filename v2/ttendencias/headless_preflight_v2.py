#!/usr/bin/env python3
"""Preflight Chrome V2 oculto: verifica ChatGPT sin enviar ningún mensaje.

El instalador debe tener la tarea V2 desactivada. Mantiene un lock exclusivo,
usa exclusivamente ChromeProfile V2 y comprueba que TODOS los procesos
lanzados se cerraron, incluidos hijos tardíos. No toca Chrome V1.
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
from chrome_cleanup_v2 import cleanup_v2_profile
from process_lock_v2 import exclusive_v2_lock


def verify_under_lock():
    if core.profile_pids():
        raise RuntimeError("Chrome V2 en uso antes de preflight: no intervenir")
    if not core.CHROME.is_file() or not core.PROFILE.is_dir():
        raise RuntimeError("Chrome o perfil V2 inexistente")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    args = command(core.CHROME, core.PROFILE, port, headless=True)
    proc = None
    browser = None
    composer_ready = False
    original_error = None
    cleanup = None
    try:
        proc = subprocess.Popen(args, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
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
            raise RuntimeError("CDP no disponible en Chrome V2 oculto")
        if not core.profile_pids():
            raise RuntimeError("No se identificaron procesos ChromeProfile V2")
        print("TT_V2_HEADLESS_CDP=YES", flush=True)
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint, timeout=18000)
            if not browser.contexts:
                raise RuntimeError("Chrome V2 no tiene contexto autenticable")
            context = browser.contexts[0]
            page = next((p for p in context.pages
                         if p.url.startswith("https://chatgpt.com/")), None)
            if page is None:
                page = context.new_page()
                page.goto("https://chatgpt.com/", wait_until="domcontentloaded",
                          timeout=45000)
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if page.url.startswith("https://chatgpt.com/"):
                    for selector in core.COMPOSERS:
                        field = page.locator(selector).first
                        if field.count() and field.is_visible() and field.is_enabled():
                            composer_ready = True
                            print("TT_V2_HEADLESS_COMPOSER_READY=YES", flush=True)
                            break
                if composer_ready:
                    break
                time.sleep(2)
            if not composer_ready:
                raise RuntimeError("ChatGPT V2 no muestra editor usable en headless")
    except Exception as exc:
        # Conservar la causa original: un fallo de limpieza NO debe ocultar
        # un problema anterior de CDP, login o editor.
        original_error = exc
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
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Solo es nuestro proceso Popen, nunca Chrome genérico/V1.
                try:
                    proc.kill()
                except OSError:
                    pass
        try:
            cleanup = cleanup_v2_profile(core.profile_pids)
            print("TT_V2_HEADLESS_CLEANUP_ROUNDS=" +
                  str(cleanup["rounds"]), flush=True)
            print("TT_V2_HEADLESS_CLEANUP_REMAINING=" +
                  str(len(cleanup["remaining"])), flush=True)
        except Exception as exc:
            if original_error:
                raise RuntimeError("Error original " + str(original_error) +
                                   "; fallo inspección cierre: " + str(exc)) from exc
            raise RuntimeError("Fallo al comprobar cierre Chrome V2: " +
                               str(exc)) from exc
    if cleanup is None or not cleanup["closed"]:
        remaining = cleanup["remaining"] if cleanup else []
        note = ("; error previo: " + str(original_error)) if original_error else ""
        raise RuntimeError("Quedan " + str(len(remaining)) +
                           " procesos Chrome V2 tras cierre (" +
                           ",".join(map(str, remaining[:12])) + ")" + note)
    print("TT_V2_HEADLESS_PROCESSES_CLOSED=YES", flush=True)
    if original_error:
        raise original_error
    if not composer_ready:
        raise RuntimeError("El editor ChatGPT V2 no llegó a estar listo")
    print("TT_V2_HEADLESS_MESSAGE_SENT=NO", flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)


def verify():
    # Evitar pruebas simultáneas con otro consumidor V2 y no tocar V1.
    with exclusive_v2_lock(core.ROOT / "editorial_batch_v2.lock"):
        verify_under_lock()


if __name__ == "__main__":
    try:
        verify()
    except Exception as exc:
        print("TT_V2_HEADLESS_PREFLIGHT_ERROR=" + str(exc),
              file=sys.stderr, flush=True)
        print("TT_V2_HEADLESS_MESSAGE_SENT=NO", flush=True)
        sys.exit(1)
