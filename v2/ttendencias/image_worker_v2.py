#!/usr/bin/env python3
"""TTActualidad V2 image-only worker: one Top30 trend, one independent Chrome.

Never edits editorial text, never publishes, never touches V1, never uses the
editorial Chrome profile. A failed image can be tried again in a NEW chat.
Only the first successful original is bound to the trend/revision.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import secrets
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone

import editorial_run_v2 as editorial
import image_github_v2 as github
import image_intake_v2 as intake
import image_job_v2 as jobs
import image_same_chat_v2 as image_page
from select_current_top30_v2 import read_history, select_current_top30

ROOT = editorial.ROOT
PROFILE = pathlib.Path(os.environ.get("TT_V2_IMAGE_PROFILE", str(ROOT / "ChromeProfileImages")))
JOURNALS = ROOT / "image-only-journals"
CHROME = editorial.CHROME
COOLDOWN_SECONDS = 240
COMPOSERS = editorial.COMPOSERS
HEADLESS = os.environ.get("TT_V2_IMAGE_CHROME_HEADLESS", "0").strip().lower() not in ("0", "false", "no")


def image_profile_pids():
    """Only image Chrome children; editorial/V1 may run at the same time."""
    ps = (
        "$p=$env:TT_V2_IMAGE_PROFILE;"
        "if (-not $p) { $p=Join-Path $env:LOCALAPPDATA 'TTActualidadV2\\ChromeProfileImages' };"
        "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | "
        "Where-Object { $_.CommandLine -and $_.CommandLine.Contains('--user-data-dir=') "
        "-and $_.CommandLine.Contains($p) } | "
        "Select-Object -ExpandProperty ProcessId | ConvertTo-Json -Compress"
    )
    run = subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps],
                         capture_output=True, text=True, timeout=20,
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if run.returncode:
        raise RuntimeError("V2_IMAGE_CHROME_PROCESS_INSPECTION_FAILED")
    raw = run.stdout.strip()
    value = json.loads(raw) if raw else []
    return set(map(int, value if isinstance(value, list) else [value]))


def eligible(row):
    cap = row.get("capture") or {}
    return (row.get("status") in ("captured_review", "ready")
            and cap.get("revision") == row.get("revision")
            and isinstance(cap.get("answer"), str) and bool(cap["answer"].strip())
            and cap.get("sha256") == intake.fingerprint(cap["answer"])
            and (cap.get("image") or {}).get("status") != "saved")


def ranked_candidates(queue, history, *, now=None):
    """Top30 in positional order, independent from editorial pending statuses."""
    # Reuse authoritative rank, freshness, completeness and revision checks.
    select_current_top30(queue, history, 30, now=now)
    by_rank = {}
    for topic in history["topics"].values():
        if topic.get("active") is True and isinstance(topic.get("rank"), int):
            if 1 <= topic["rank"] <= 30:
                by_rank[topic["rank"]] = topic["trend_id"]
    return [queue["items"][by_rank[rank]] for rank in range(1, 31)
            if eligible(queue["items"].get(by_rank[rank]) or {})]


def journal_path(trend_id, revision, attempt):
    return JOURNALS / ("%s-r%d-attempt-%03d.json" % (trend_id, revision, attempt))


def next_attempt(row, *, now=None):
    """Retries are allowed; a recent failed attempt only delays its own trend."""
    now = now or datetime.now(timezone.utc)
    tid, rev = row["trend_id"], row["revision"]
    previous = sorted(JOURNALS.glob("%s-r%d-attempt-*.json" % (tid, rev)))
    if len(previous) >= 99:
        return None  # No reciclar el identificador de comando del intento 99.
    if previous:
        last = json.loads(previous[-1].read_text(encoding="utf-8"))
        if last.get("status") not in ("saved", "bound_by_other"):
            stamp = datetime.fromisoformat(last["at"])
            if (now - stamp).total_seconds() < COOLDOWN_SECONDS:
                return None
    return len(previous) + 1


def pick_next(queue, history, *, now=None):
    for row in ranked_candidates(queue, history, now=now):
        attempt = next_attempt(row, now=now)
        if attempt is not None:
            return row, attempt
    return None, None


def new_image_chat(context, command_id):
    """One fresh conversation; find the exact prompted turn, not other tabs."""
    page = context.new_page()
    page.goto("https://chatgpt.com/", wait_until="domcontentloaded", timeout=45000)
    composer = None
    until = time.monotonic() + 100
    while time.monotonic() < until:
        for selector in COMPOSERS:
            node = page.locator(selector).first
            if node.count() and node.is_visible() and node.is_enabled():
                composer = node
                break
        if composer is not None:
            break
        time.sleep(2)
    if composer is None:
        raise RuntimeError("V2_IMAGE_PROFILE_LOGIN_REQUIRED")
    return page, composer


def run_one(row, attempt, *, api, auth):
    """Isolated lifecycle, safe even while editorial Chrome is running."""
    tid, rev = row["trend_id"], row["revision"]
    if image_profile_pids():
        raise RuntimeError("V2_IMAGE_OWN_PROFILE_ALREADY_RUNNING")
    if not CHROME.exists():
        raise RuntimeError("V2_IMAGE_CHROME_NOT_FOUND")
    if not PROFILE.is_dir():
        raise RuntimeError("V2_IMAGE_PROFILE_LOGIN_REQUIRED")
    if journal_path(tid, rev, attempt).exists():
        raise RuntimeError("V2_IMAGE_ATTEMPT_ALREADY_RECORDED_NO_RESEND")
    # The job is immutable for this attempt. Its destination chat URL will be
    # updated only after ChatGPT's new conversation is proven to contain it.
    job = jobs.proposed_job(row, attempt=min(attempt, 99),
                            nonce=secrets.token_hex(12))
    github.current_editorial(job, auth)
    JOURNALS.mkdir(parents=True, exist_ok=True)
    journal = journal_path(tid, rev, attempt)
    record = {"at": datetime.now(timezone.utc).isoformat(),
              "trend_id": tid, "revision": rev, "attempt": attempt,
              "command_id": job["command_id"], "status": "starting",
              "publication_allowed": False}
    editorial.store(journal, record)
    process = None
    browser = None
    hider = None
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        if port in (9223, 9234):
            raise RuntimeError("V2_IMAGE_V1_PORT_RESERVED")
        chrome_command = editorial.module("chrome_command_v2.py", "ttv2_image_chrome_cmd")
        visibility = editorial.module("chrome_visibility_v2.py", "ttv2_image_visibility")
        argv = chrome_command.command(CHROME, PROFILE, port,
                                      headless=HEADLESS, hidden=not HEADLESS)
        process = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,
                                   startupinfo=visibility.startupinfo_hidden() if not HEADLESS else None,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if not HEADLESS:
            hider = visibility.V2WindowHider(image_profile_pids, primary_pid=process.pid).start()
        endpoint = "http://127.0.0.1:%d" % port
        import urllib.request
        for _ in range(40):
            try:
                with urllib.request.urlopen(endpoint + "/json/version", timeout=3) as response:
                    json.load(response)
                break
            except Exception:
                time.sleep(1)
        else:
            raise RuntimeError("V2_IMAGE_CDP_NOT_READY")
        if not image_profile_pids():
            raise RuntimeError("V2_IMAGE_OWN_CHROME_NOT_IDENTIFIED")
        if hider and hider.last_error:
            raise RuntimeError("V2_IMAGE_HIDDEN_CHROME_FAILED")
        if hider:
            hider.ensure_hidden()
        from playwright.sync_api import sync_playwright
        with sync_playwright() as pw:
            browser = pw.chromium.connect_over_cdp(endpoint)
            context = browser.contexts[0]
            page, composer = new_image_chat(context, job["command_id"])
            tracker = editorial.module("image_target_tracker_v2.py", "ttv2_image_target_tracker")
            baseline = tracker.image_conversation_urls(browser)
            # An attempt may be repeated in a NEW chat after a timeout.
            # Do not send this same attempt twice if the process is interrupted.
            record["status"] = "send_intent_recorded"
            editorial.store(journal, record)
            composer.fill(job["prompt"])
            composer.press("Enter")
            record["status"] = "sent_waiting_for_image"
            editorial.store(journal, record)
            page, discovery = tracker.await_image_conversation(
                browser, page, job["command_id"], seconds=150,
                baseline_urls=baseline)
            record["chat_discovery"] = discovery
            editorial.store(journal, record)
            if page is None:
                raise RuntimeError("V2_IMAGE_NEW_CHAT_ID_NOT_VERIFIED")
            url = discovery["url"]
            job["conversation_url"] = url
            record["image_chat_url"] = url
            editorial.store(journal, record)
            raw = image_page.original_from_same_page(page, job, timeout=480)
            intake.persist_original(ROOT / "image-originals", job, raw)
            try:
                saved = github.save_original(job, raw, auth)
            except RuntimeError as exc:
                if str(exc) == "V2_IMAGE_REVISION_ALREADY_BOUND":
                    record["status"] = "bound_by_other"
                    editorial.store(journal, record)
                    return record
                raise
            receipt = {key: saved[key] for key in
                       ("sha256", "path", "mime", "revision", "backend", "command_id")}
            receipt["status"] = "saved"
            receipt["image_chat_url"] = url
            editorial.update_image_receipt(api, auth, tid, rev, job["editorial_sha256"], receipt)
            verified, _ = editorial.queue_read(api, auth)
            bound = ((verified["items"].get(tid) or {}).get("capture") or {}).get("image") or {}
            if bound.get("status") != "saved":
                raise RuntimeError("V2_IMAGE_QUEUE_RECEIPT_NOT_SAVED")
            record["status"] = ("saved" if bound.get("sha256") == saved["sha256"]
                                else "bound_by_other")
            editorial.store(journal, record)
            try:
                web = editorial.module("web_top30_v2.py", "ttv2_image_web")
                web.sync_to_github(auth)
                record["web_projection"] = "synced"
            except Exception as exc:
                record["web_projection"] = "retry_later:" + type(exc).__name__
            editorial.store(journal, record)
            try:
                browser.new_browser_cdp_session().send("Browser.close")
            except Exception:
                pass
        print("TT_V2_IMAGE_BOUND=" + record["status"].upper(), flush=True)
        return record
    except Exception as exc:
        record["status"] = "failed"
        record["error"] = str(exc)[:250]
        editorial.store(journal, record)
        raise
    finally:
        if hider:
            hider.stop()
        if browser:
            try:
                browser.close()
            except Exception:
                pass
        if process:
            try:
                process.wait(timeout=7)
            except subprocess.TimeoutExpired:
                try:
                    process.kill()
                except OSError:
                    pass
        cleanup = editorial.module("chrome_cleanup_v2.py", "ttv2_image_cleanup")
        result = cleanup.cleanup_v2_profile(image_profile_pids)
        print("TT_V2_IMAGE_CHROME_CLOSED=" + ("YES" if result["closed"] else "NO"), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-one", action="store_true",
                        help="Generate one image on a separate ChatGPT conversation")
    parser.add_argument("--trend-id", help="ID reservado por el despachador paralelo")
    parser.add_argument("--revision", type=int)
    parser.add_argument("--attempt", type=int)
    args = parser.parse_args()
    api = editorial.module("persist_capture_github.py", "ttv2_image_github_api")
    auth = api.token()
    queue, _ = editorial.queue_read(api, auth)
    history = read_history(auth)
    if args.trend_id:
        if not args.run_one or args.revision is None or args.attempt is None:
            raise RuntimeError("V2_IMAGE_EXPLICIT_JOB_INCOMPLETE")
        row = next((candidate for candidate in ranked_candidates(queue, history)
                    if candidate["trend_id"] == args.trend_id
                    and candidate["revision"] == args.revision), None)
        if row is None:
            raise RuntimeError("V2_IMAGE_EXPLICIT_JOB_NOT_CURRENT_TOP30")
        attempt = next_attempt(row)
        if attempt != args.attempt:
            raise RuntimeError("V2_IMAGE_ATTEMPT_STALE_NO_RESEND")
    else:
        row, attempt = pick_next(queue, history)
    print("TT_V2_IMAGE_SELECTION=CURRENT_TOP30_RANK_ORDER")
    print("TT_V2_IMAGE_NEXT=" + ((row["name"] + ":r" + str(row["revision"])) if row else "NONE"))
    print("TT_V2_IMAGE_ATTEMPT=" + str(attempt or 0))
    print("TT_V2_IMAGE_PUBLICATION=NO")
    if row and args.run_one:
        run_one(row, attempt, api=api, auth=auth)
    else:
        print("TT_V2_IMAGE_DRY_RUN=YES")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_IMAGE_WORKER_ERROR=" + str(exc)[:250], file=sys.stderr)
        sys.exit(1)
