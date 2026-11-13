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
from chrome_startup_v2 import wait_for_cdp
from chrome_visibility_v2 import V2WindowHider, startupinfo_hidden
from process_lock_v2 import exclusive_v2_lock


def verify_under_lock():
    if core.profile_pids():
        raise RuntimeError("Chrome V2 en uso antes de preflight: no intervenir")
    if not core.CHROME.is_file() or not core.PROFILE.is_dir():
        raise RuntimeError("Chrome o perfil V2 inexistente")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    # Previously tested headless has CDP but no authenticated composer.
    # Use normal headed Chrome with its own windows hidden (no headless).
    args = command(core.CHROME, core.PROFILE, port, headless=False, hidden=True)
    proc = None
    browser = None
    hider = None
    chrome_stderr = None
    chrome_error_log = core.ROOT / "install-chrome-headless.stderr.log"
    composer_ready = False
    original_error = None
    cleanup = None
    try:
        # Chrome Windows may exit its launcher after moving the browser
        # to child processes; don't confuse launcher exit with CDP failure.
        # Keep Chrome's own diagnostics locally instead of discarding stderr.
        chrome_stderr = chrome_error_log.open("w", encoding="utf-8")
        proc = subprocess.Popen(args + ["--enable-logging=stderr"], stdout=subprocess.DEVNULL,
                                stderr=chrome_stderr,
                                startupinfo=startupinfo_hidden(),
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        hider = V2WindowHider(core.profile_pids).start()
        print("TT_V2_CHROME_MODE=HEADED_HIDDEN", flush=True)
        endpoint = "http://127.0.0.1:" + str(port)
        def cdp_ready():
            try:
                with urllib.request.urlopen(endpoint + "/json/version", timeout=2) as resp:
                    return bool(json.load(resp).get("Browser"))
            except (OSError, ValueError):
                return False
        startup = wait_for_cdp(proc, cdp_ready, core.profile_pids,
                               attempts=40, delay=time.sleep, absent_limit=6)
        print("TT_V2_CHROME_LAUNCHER_EXITED=" +
              ("YES" if startup["launcher_exited"] else "NO"), flush=True)
        print("TT_V2_CHROME_SCOPED_CHILD_SEEN=" +
              ("YES" if startup["children_seen"] else "NO"), flush=True)
        if not core.profile_pids():
            raise RuntimeError("No se identificaron procesos ChromeProfile V2")
        print("TT_V2_HIDDEN_CDP=YES", flush=True)
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
                            print("TT_V2_HIDDEN_COMPOSER_READY=YES", flush=True)
                            break
                if composer_ready:
                    break
                time.sleep(2)
            if not composer_ready:
                # Diagnostic contains no prompt, conversation body, cookie or token.
                print("TT_V2_HIDDEN_PAGE_HOST=" + (page.url.split("/")[2] if "://" in page.url else "unknown"), flush=True)
                print("TT_V2_HIDDEN_PAGE_LOGIN=" + str("auth" in page.url.lower() or "login" in page.url.lower()).upper(), flush=True)
                raise RuntimeError("ChatGPT V2 no muestra editor usable en Chrome normal oculto")
    except Exception as exc:
        # Conservar la causa original: un fallo de limpieza NO debe ocultar
        # un problema anterior de CDP, login o editor.
        original_error = exc
    finally:
        if hider:
            hider.stop()
            print("TT_V2_WINDOW_HIDER_STATUS=" + ("OK" if not hider.last_error else "ERROR"), flush=True)
            if hider.last_error and not original_error:
                original_error = RuntimeError("No se pudo mantener Chrome V2 oculto: " + hider.last_error)
        if browser:
            try:
                browser.new_browser_cdp_session().send("Browser.close")
            except Exception:
                pass
            try:
                browser.close()
            except Exception:
                pass
        if chrome_stderr:
            chrome_stderr.close()
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
    print("TT_V2_HIDDEN_PROCESSES_CLOSED=YES", flush=True)
    if original_error:
        raise original_error
    if not composer_ready:
        raise RuntimeError("El editor ChatGPT V2 no llegó a estar listo")
    print("TT_V2_HIDDEN_MESSAGE_SENT=NO", flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)


def verify():
    # Evitar pruebas simultáneas con otro consumidor V2 y no tocar V1.
    with exclusive_v2_lock(core.ROOT / "editorial_batch_v2.lock"):
        verify_under_lock()


if __name__ == "__main__":
    try:
        verify()
    except Exception as exc:
        print("TT_V2_HIDDEN_PREFLIGHT_ERROR=" + str(exc),
              file=sys.stderr, flush=True)
        print("TT_V2_HIDDEN_CHROME_STDERR_LOG=" +
              str(core.ROOT / "install-chrome-headless.stderr.log"),
              flush=True)
        print("TT_V2_HEADLESS_MESSAGE_SENT=NO", flush=True)
        sys.exit(1)
