#!/usr/bin/env python3
"""V2: descubrir conversación de un envío anterior SIN enviar instrucciones.

Consulta historial ChromeProfile y, si hace falta, enlaces visibles de la barra
lateral. Abre y cierra SOLO Chrome V2; no escribe en GitHub ni modifica V1.
"""
import argparse
import json
import pathlib
import re
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
from datetime import datetime, timezone

from playwright.sync_api import sync_playwright
import editorial_run_v2 as core

CHAT = re.compile(r"^https://chatgpt\.com/c/[A-Za-z0-9-]{16,80}(?:[?#].*)?$")
STOP = core.STOP

def canonical(url):
    clean = url.split("?", 1)[0].split("#", 1)[0]
    return clean if CHAT.fullmatch(clean) else None

def history_candidates(limit=60):
    paths = [core.PROFILE / "Default" / "History"]
    paths += list(core.PROFILE.glob("Profile */History"))
    found = {}
    for p in paths:
        if not p.exists():
            continue
        with tempfile.TemporaryDirectory(prefix="ttv2-history-") as temp:
            dest = pathlib.Path(temp) / "History"
            try:
                shutil.copy2(p, dest)
                conn = sqlite3.connect(str(dest))
                try:
                    rows = conn.execute(
                        "SELECT url, last_visit_time FROM urls "
                        "WHERE url LIKE 'https://chatgpt.com/c/%' "
                        "ORDER BY last_visit_time DESC LIMIT ?", (limit,)
                    ).fetchall()
                finally:
                    conn.close()
                for url, when in rows:
                    key = canonical(url)
                    if key:
                        found[key] = max(found.get(key, 0), int(when or 0))
            except (OSError, sqlite3.Error) as exc:
                print("TT_V2_HISTORY_WARNING=" + type(exc).__name__, flush=True)
    return [u for u, _ in sorted(found.items(), key=lambda kv: -kv[1])][:limit]

def prompt_present(body, trend_id, revision):
    # Constrain search to conversation user prompt, not navigation/recent title.
    matches = re.findall(r"(?:^|\n)(?:You said:|Tú dijiste:)\s*\n(.*?)(?=\n(?:ChatGPT said:|ChatGPT respondió:|You said:|Tú dijiste:)|\Z)", body, re.S)
    expected = re.compile(r"\brevisi[oó]n\s*[: ]\s*" + str(revision) + r"\b", re.I)
    return any(trend_id in m and expected.search(m) for m in matches)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trend-id", required=True)
    parser.add_argument("--revision", required=True, type=int)
    parser.add_argument("--limit", type=int, default=35)
    args = parser.parse_args()
    if not re.fullmatch(r"trv2-[a-f0-9]{24}", args.trend_id):
        raise ValueError("ID inválido")
    if args.revision < 1 or not 1 <= args.limit <= 80:
        raise ValueError("Revisión/límite fuera de rango")
    journal = core.DIAG_DIR / f"run-{args.trend_id}-r{args.revision}.json"
    d = json.loads(journal.read_text(encoding="utf-8-sig"))
    if (d.get("trend_id") != args.trend_id or d.get("revision") != args.revision
        or d.get("message_sent") is not True or not d.get("lease_token")):
        raise RuntimeError("No hay envío previo confirmado; abortar")
    if core.profile_pids():
        raise RuntimeError("El Chrome exclusivo V2 ya está abierto")
    candidates = history_candidates(args.limit)
    print("TT_V2_HISTORY_CONVERSATIONS=" + str(len(candidates)), flush=True)
    result = {"trend_id": args.trend_id, "revision": args.revision, "message_sent": False,
              "published": False, "github_write": False, "found": False,
              "candidate_count": len(candidates), "checked_urls": [],
              "observed_at": datetime.now(timezone.utc).isoformat()}
    owned = set()
    proc = None
    browser = None
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        if port in (9223, 9234):
            raise RuntimeError("Puerto V1 reservado")
        proc = subprocess.Popen([str(core.CHROME), f"--user-data-dir={core.PROFILE}",
            f"--remote-debugging-port={port}", "--remote-debugging-address=127.0.0.1",
            "--disable-extensions", "--no-first-run", "--no-default-browser-check",
            "--new-window", "https://chatgpt.com/"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        endpoint = f"http://127.0.0.1:{port}"
        for _ in range(40):
            try:
                with urllib.request.urlopen(endpoint + "/json/version", timeout=3) as res:
                    json.load(res)
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("CDP no disponible")
        owned = core.profile_pids()
        if not owned:
            raise RuntimeError("No se identificaron procesos V2")
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint)
            context = browser.contexts[0]
            page = next((p for p in context.pages if p.url.startswith("https://chatgpt.com/")), None)
            if page is None:
                page = context.new_page()
                page.goto("https://chatgpt.com/", wait_until="domcontentloaded", timeout=30000)
            # Sidebar fallback (current page only) after UI loads.
            for _ in range(12):
                try:
                    links = page.locator("a[href*='/c/']").evaluate_all(
                        "(nodes)=>nodes.map(x=>x.href).filter(Boolean)"
                    )
                    for u in links:
                        c = canonical(u)
                        if c and c not in candidates:
                            candidates.append(c)
                    if links: break
                except Exception: pass
                time.sleep(1)
            result["candidate_count"] = len(candidates)
            # These are only READ navigations; no form fill, no Enter, no clicks.
            for url in candidates[:args.limit]:
                try:
                    page.goto(url, wait_until="domcontentloaded", timeout=18000)
                    for _ in range(6):
                        body = page.locator("body").inner_text(timeout=5000)
                        if prompt_present(body, args.trend_id, args.revision):
                            result["found"] = True
                            result["chat_url"] = url
                            result["reply_visible"] = "ChatGPT said:" in body or "ChatGPT respondió:" in body
                            break
                        time.sleep(1)
                    result["checked_urls"].append(url)
                    if result["found"]: break
                except Exception as exc:
                    result["checked_urls"].append(url)
                    result.setdefault("errors", []).append(type(exc).__name__)
            try: browser.new_browser_cdp_session().send("Browser.close")
            except Exception: pass
    except Exception as exc:
        result["error"] = str(exc)[:300]
    finally:
        if browser:
            try: browser.close()
            except Exception: pass
        if proc:
            try: proc.wait(timeout=10)
            except subprocess.TimeoutExpired: pass
        remaining = core.profile_pids()
        for pid in remaining & owned:
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True, timeout=15)
        time.sleep(2)
        remaining = core.profile_pids()
        result["cleanup_verified"] = bool(proc) and not remaining
        result["remaining_v2_pids"] = sorted(remaining)
        core.store(core.DIAG_DIR / ("discover-" + args.trend_id + ".json"), result)
    print("TT_V2_CONVERSATION_FOUND=" + ("YES" if result["found"] else "NO"), flush=True)
    if result.get("chat_url"): print("TT_V2_CHAT_URL=" + result["chat_url"], flush=True)
    print("TT_V2_REMAINING_PROCESSES=" + str(len(result["remaining_v2_pids"])), flush=True)
    print("TT_V2_GITHUB_WRITE=NO", flush=True)
    print("TT_V2_MESSAGE_SENT=NO", flush=True)
    print("TT_V2_PUBLISHED=NO", flush=True)
    if result.get("error"):
        raise RuntimeError(result["error"])

if __name__ == "__main__":
    main()
