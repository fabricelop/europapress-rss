#!/usr/bin/env python3
"""TTActualidad V2 image-only worker: one Top30 trend, one independent Chrome.

Never edits editorial text, never publishes, never touches V1, never uses the
editorial Chrome profile. A failed image can be tried again in a NEW chat.
The latest successful image replaces the previous raster for that trend.
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
from datetime import datetime, timedelta, timezone

import editorial_run_v2 as editorial
from chrome_profile_process_v2 import exact_chrome_profile_pids
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
IMAGE_SEND_PROTOCOL = 2
MAX_PROTOCOL_ATTEMPTS = 3
MAX_PRE_SEND_FAILURES = 3
UNVERIFIED_SEND_COOLDOWN_SECONDS = COOLDOWN_SECONDS
COMPOSERS = editorial.COMPOSERS
SEND_BUTTONS = (
    'button[data-testid="send-button"]',
    'button[data-testid="composer-send-button"]',
    'button[data-testid="send-message-button"]',
    'button[aria-label="Send"]',
    'button[aria-label="Enviar"]',
    'button[aria-label="Enviar prompt"]',
    'button[aria-label="Send prompt"]',
    'button[aria-label="Send message"]',
    'button[aria-label="Enviar mensaje"]',
)
HEADLESS = os.environ.get("TT_V2_IMAGE_CHROME_HEADLESS", "0").strip().lower() not in ("0", "false", "no")

# Public diagnostics are a closed vocabulary. Raw Playwright/HTTP errors can
# contain conversation URLs, request headers, cookies or executable paths.
IMAGE_FAILURE_DETAILS = {
    "V2_IMAGE_WORKER_FAILED": "No se pudo completar la imagen. Revise el proceso local de imágenes.",
    "V2_IMAGE_PROFILE_LOGIN_REQUIRED": "El perfil de imágenes necesita una sesión de ChatGPT válida.",
    "V2_IMAGE_CHROME_NOT_FOUND": "No se encontró el navegador configurado para imágenes.",
    "V2_IMAGE_CDP_NOT_READY": "El navegador de imágenes no terminó de arrancar.",
    "V2_IMAGE_OWN_CHROME_NOT_IDENTIFIED": "No se pudo verificar el navegador propio del trabajo.",
    "V2_IMAGE_OWN_PROFILE_ALREADY_RUNNING": "El perfil de imágenes ya está ocupado por otro proceso.",
    "V2_IMAGE_HIDDEN_CHROME_FAILED": "No se pudo comprobar el modo oculto del navegador de imágenes.",
    "V2_IMAGE_V1_PORT_RESERVED": "El navegador no pudo obtener un puerto independiente.",
    "V2_IMAGE_NEW_CHAT_ID_NOT_VERIFIED": "No se pudo confirmar la conversación nueva de imágenes.",
    "V2_IMAGE_COMPOSER_UNAVAILABLE": "No se encontró el cuadro para enviar el encargo de imagen.",
    "V2_IMAGE_PROMPT_NOT_IN_COMPOSER": "No se pudo comprobar el encargo antes de enviarlo.",
    "V2_IMAGE_PROMPT_NOT_SUBMITTED": "El encargo no llegó a enviarse a ChatGPT.",
    "V2_IMAGE_SEND_BUTTON_DISABLED": "ChatGPT no permitió enviar el encargo de imagen.",
    "V2_IMAGE_SEND_BUTTON_UNAVAILABLE": "No se encontró un botón de envío verificable; no se pulsó Enter.",
    "V2_IMAGE_SEND_UNVERIFIED_NO_RESEND": "El envío quedó sin confirmar. No se repetirá a ciegas.",
    "V2_IMAGE_SEND_UNCERTAIN_NO_RESEND": "El envío quedó sin confirmar. Debe recuperarse la misma conversación.",
    "V2_IMAGE_NOT_READY": "No se recuperó una imagen terminada dentro del tiempo de espera.",
    "V2_IMAGE_CHAT_CHANGED": "La conversación no coincide con la asignada a esta imagen.",
    "V2_IMAGE_WRONG_CHAT_JOB": "La conversación no contiene el encargo exacto de esta imagen.",
    "V2_IMAGE_EDITORIAL_CHAT_NOT_VERIFIED": "No se pudo verificar el contexto editorial de la imagen.",
    "V2_IMAGE_EDITORIAL_TURN_CHANGED": "El contexto editorial cambió durante el trabajo de imagen.",
    "V2_IMAGE_EDITORIAL_CHANGED": "La revisión editorial cambió antes de asociar la imagen.",
    "V2_IMAGE_BROWSER_RASTER_MISMATCH": "La imagen recuperada no coincide con el original del navegador.",
    "V2_IMAGE_ORIGINAL_SIZE_INVALID": "El archivo recuperado no tiene un tamaño de imagen válido.",
    "V2_IMAGE_ORIGINAL_FORMAT_OR_DIMENSIONS_INVALID": "El original no cumple el formato o las dimensiones requeridas.",
    "V2_IMAGE_GITHUB_AUTH_MISSING": "Falta la autenticación necesaria para guardar la imagen.",
    "V2_IMAGE_GITHUB_HTTP_ERROR": "No se pudo completar la comunicación para guardar la imagen.",
    "V2_IMAGE_GITHUB_COMMIT_MISSING": "El guardado de la imagen no obtuvo confirmación.",
    "V2_IMAGE_GITHUB_READBACK_FAILED": "No se pudo releer la imagen guardada para verificarla.",
    "V2_IMAGE_GITHUB_WRITE_UNVERIFIED": "No se pudo verificar el guardado de la imagen.",
    "V2_IMAGE_GITHUB_EXISTING_RASTER_CONFLICT": "Ya existe otro original para esta identidad editorial.",
    "V2_IMAGE_GITHUB_CONFLICT_NO_REPLAY": "El guardado coincidió con otro cambio y necesita revisión.",
    "V2_IMAGE_QUEUE_RECEIPT_NOT_SAVED": "No se confirmó la asociación de la imagen con esta revisión.",
    "V2_IMAGE_REMOTE_RECEIPT_INVALID": "La confirmación de imagen recibida no es válida.",
    "V2_IMAGE_RECEIPT_CONFLICT": "La confirmación corresponde a otro trabajo de imagen.",
    "V2_IMAGE_LOCAL_ORIGINAL_CONFLICT": "La copia local del original tiene una identidad distinta.",
    "V2_IMAGE_ATTEMPT_ALREADY_RECORDED_NO_RESEND": "Este intento ya está registrado y no se repetirá a ciegas.",
}


def safe_image_failure(exc):
    """Map only exact known codes; never publish arbitrary exception text."""
    raw = str(exc)
    if raw in IMAGE_FAILURE_DETAILS:
        code = raw
    elif raw.startswith("V2_IMAGE_NOT_READY:"):
        code = "V2_IMAGE_NOT_READY"
    elif re.fullmatch(r"V2_IMAGE_GITHUB_HTTP_[1-5][0-9]{2}", raw):
        code = "V2_IMAGE_GITHUB_HTTP_ERROR"
    else:
        code = "V2_IMAGE_WORKER_FAILED"
    return {"code": code, "detail_safe": IMAGE_FAILURE_DETAILS[code],
            "retry_mode": "new_chat_replace_previous" if code in (
                "V2_IMAGE_SEND_UNVERIFIED_NO_RESEND", "V2_IMAGE_SEND_UNCERTAIN_NO_RESEND",
                "V2_IMAGE_NEW_CHAT_ID_NOT_VERIFIED", "V2_IMAGE_ATTEMPT_ALREADY_RECORDED_NO_RESEND",
                "V2_IMAGE_PROMPT_NOT_SUBMITTED", "V2_IMAGE_NOT_READY")
            else "manual_only"


def persist_image_incident(api, auth, job, exc, *, at=None):
    """CAS the current revision's failure and verify it without changing text.

    No retry/generation policy is altered. An older failed attempt cannot replace
    a newer active attempt, a newer incident or a successfully attached original.
    """
    tid, rev, command = job["trend_id"], job["revision"], job["command_id"]
    expected_hash = job["editorial_sha256"]
    if (not re.fullmatch(r"trv2-[a-f0-9]{24}", str(tid)) or type(rev) is not int or rev < 1
        or not re.fullmatch(r"[a-f0-9]{64}", str(expected_hash))
        or not re.fullmatch(r"v2-img-" + re.escape(tid) + r"-r" + str(rev) + r"-a[1-9][0-9]*-[A-Za-z0-9_-]{8,60}", str(command))):
        raise RuntimeError("V2_IMAGE_INCIDENT_IDENTITY_INVALID")
    when = at or datetime.now(timezone.utc)
    if not isinstance(when, datetime) or when.tzinfo is None or when.utcoffset() is None:
        raise RuntimeError("V2_IMAGE_INCIDENT_TIMESTAMP_INVALID")
    incident = {"project": "ttendencias-v2", "trend_id": tid, "revision": rev,
                "editorial_sha256": expected_hash, "command_id": command,
                "at": when.astimezone(timezone.utc).isoformat(), **safe_image_failure(exc)}
    for retry in range(6):
        queue, sha = editorial.queue_read(api, auth)
        row = (queue.get("items") or {}).get(tid) or {}
        cap = row.get("capture") or {}
        if (row.get("status") not in ("captured_review", "ready") or row.get("revision") != rev
            or cap.get("revision") != rev or cap.get("sha256") != expected_hash
            or (cap.get("image") or {}).get("status") == "saved"):
            return False
        progress = row.get("image_progress") or {}
        if progress.get("status") == "in_progress" and progress.get("command_id") != command:
            try:
                expiry = datetime.fromisoformat(progress.get("expires_at", "").replace("Z", "+00:00"))
                if expiry.tzinfo and expiry > datetime.now(timezone.utc):
                    return False
            except (ValueError, TypeError, AttributeError):
                return False  # uncertain ownership cannot be overwritten
        current = row.get("image_incident") or {}
        if (current.get("command_id") == command and current.get("code") == incident["code"]
            and current.get("revision") == rev and current.get("editorial_sha256") == expected_hash):
            # Readback/retry after a lost write response is idempotent.
            return True
        if current.get("revision") == rev and current.get("editorial_sha256") == expected_hash:
            try:
                previous_at = datetime.fromisoformat(current.get("at", "").replace("Z", "+00:00"))
                if previous_at.tzinfo and previous_at > when:
                    return False
            except (ValueError, TypeError, AttributeError):
                pass
        row["image_incident"] = incident
        try:
            editorial.queue_write(api, auth, sha, queue, "record image incident " + tid)
            verified, _ = editorial.queue_read(api, auth)
            latest = (verified.get("items") or {}).get(tid) or {}
            saved = (latest.get("capture") or {}).get("image") or {}
            if saved.get("status") == "saved":
                return False
            if (latest.get("revision") == rev and (latest.get("capture") or {}).get("sha256") == expected_hash
                and latest.get("image_incident") == incident):
                return True
            raise RuntimeError("V2_IMAGE_INCIDENT_READBACK_UNVERIFIED")
        except Exception:
            # Re-read before any retry: a timeout may already have committed.
            # The original image failure is reported separately and never resent.
            if retry == 5:
                raise RuntimeError("V2_IMAGE_INCIDENT_PERSISTENCE_UNVERIFIED") from None
            time.sleep(min(retry + 1, 4))
    return False


def record_image_failure(api, auth, job, exc, *, journal=None, record=None):
    """Best-effort reporting cannot mask the image failure or block READY text."""
    try:
        persisted = persist_image_incident(api, auth, job, exc)
        projection = sync_image_progress(auth) if persisted else "not_current_revision"
    except Exception:
        persisted, projection = False, "incident_persistence_unverified"
    if record is not None:
        record["image_incident_persisted"] = persisted
        record["image_incident_projection"] = projection
        if journal is not None:
            editorial.store(journal, record)
    return persisted


def image_profile_pids():
    """Only image Chrome children; editorial/V1 may run at the same time."""
    return exact_chrome_profile_pids(PROFILE)


def eligible(row):
    cap = row.get("capture") or {}
    return (row.get("status") in ("captured_review", "ready")
            and cap.get("revision") == row.get("revision")
            and isinstance(cap.get("answer"), str) and bool(cap["answer"].strip())
            and cap.get("sha256") == intake.fingerprint(cap["answer"])
            and (cap.get("image") or {}).get("status") != "saved")


def ranked_candidates(queue, history, *, now=None):
    """Current Top30 plus recent RE/RE-X revisions that left the ranking.

    Historical first revisions are not an unlimited image backlog. A recent,
    explicitly reworked revision remains entitled to its own new image even
    after the radar changes. Delivery/journal anti-duplicate guards still apply.
    """
    # Reuse authoritative rank, freshness, completeness and revision checks.
    select_current_top30(queue, history, 30, now=now)
    by_rank = {}
    for topic in history["topics"].values():
        if topic.get("active") is True and isinstance(topic.get("rank"), int):
            if 1 <= topic["rank"] <= 30:
                by_rank[topic["rank"]] = topic["trend_id"]
    active = [queue["items"][by_rank[rank]] for rank in range(1, 31)
              if eligible(queue["items"].get(by_rank[rank]) or {})]
    active_ids = {row["trend_id"] for row in active}
    now = now or datetime.now(timezone.utc)
    recovered = []
    for row in queue["items"].values():
        if row.get("trend_id") in active_ids or not eligible(row):
            continue
        if row.get("revision", 0) <= 1 or row.get("reason") not in (
            "user_reexplanation", "retry_after_incident",
            "retry_after_incident_with_hints"):
            continue
        cap = row.get("capture") or {}
        try:
            captured_at = datetime.fromisoformat(str(cap["captured_at"]).replace("Z", "+00:00"))
            if captured_at.tzinfo is None or not timedelta(0) <= now-captured_at <= timedelta(hours=72):
                continue
        except (KeyError, TypeError, ValueError):
            continue
        recovered.append(row)
    recovered.sort(key=lambda row: row["capture"]["captured_at"], reverse=True)
    # Alternate new Top30 images and recent RE images. No category starves.
    result = []
    for index in range(max(len(active), min(len(recovered), 20))):
        if index < len(active):
            result.append(active[index])
        if index < min(len(recovered), 20):
            result.append(recovered[index])
    return result


def update_image_progress(api, auth, job, *, active):
    """Best-effort, revision-bound progress signal for the private V2 list.

    An interrupted worker cannot leave a permanent 'generating' icon: the
    public projection checks expiry and exact editorial fingerprint.
    """
    tid, rev, command = job["trend_id"], job["revision"], job["command_id"]
    for retry in range(6):
        queue, sha = editorial.queue_read(api, auth)
        row = (queue.get("items") or {}).get(tid) or {}
        cap = row.get("capture") or {}
        if (row.get("revision") != rev or cap.get("revision") != rev
            or cap.get("sha256") != job["editorial_sha256"]
            or row.get("status") not in ("captured_review", "ready")):
            return False
        current = row.get("image_progress") or {}
        if active:
            if (cap.get("image") or {}).get("status") == "saved":
                return False
            if (current.get("status") == "in_progress"
                and current.get("command_id") != command):
                try:
                    existing_expiry = datetime.fromisoformat(
                        current.get("expires_at", "").replace("Z", "+00:00"))
                    if existing_expiry.tzinfo and existing_expiry > datetime.now(timezone.utc):
                        return False
                except (ValueError, TypeError, AttributeError):
                    pass
            now = datetime.now(timezone.utc)
            row["image_progress"] = {
                "status": "in_progress", "revision": rev,
                "editorial_sha256": job["editorial_sha256"],
                "command_id": command,
                "started_at": now.isoformat(),
                "expires_at": (now + timedelta(minutes=25)).isoformat()
            }
        else:
            if current.get("command_id") != command:
                return False
            row.pop("image_progress", None)
        try:
            editorial.queue_write(api, auth, sha, queue,
                                  ("start image " if active else "finish image ") + tid)
            return True
        except RuntimeError as exc:
            if "GitHub conflict/changed revision" not in str(exc) or retry == 5:
                raise
            time.sleep(min(retry + 1, 4))
    return False


def sync_image_progress(auth):
    try:
        web = editorial.module("web_top30_v2.py", "ttv2_image_progress_web")
        web.sync_to_github(auth)
        return "synced"
    except Exception as exc:
        return "retry_later:" + type(exc).__name__


def journal_path(trend_id, revision, attempt):
    return JOURNALS / ("%s-r%d-attempt-%03d.json" % (trend_id, revision, attempt))


def next_attempt(row, *, now=None):
    """Retry in a NEW chat; a later successful image replaces the prior raster.

    A possibly-sent prompt is never replayed with the same command. A new
    command/chat is allowed after cleanup and cooldown, with separate bounded
    budgets for actual sends and failures proven to happen before sending.
    """
    now = now or datetime.now(timezone.utc)
    tid, rev = row["trend_id"], row["revision"]
    attempts = []
    for path in JOURNALS.glob("%s-r%d-attempt-*.json" % (tid, rev)):
        try:
            number = int(path.stem.rsplit("-", 1)[1])
            record = json.loads(path.read_text(encoding="utf-8"))
            attempts.append((number, record))
        except (ValueError, KeyError, json.JSONDecodeError):
            return None  # Corrupt/ambiguous journal identity: fail closed.
    attempts.sort(key=lambda item: item[0])
    if not attempts:
        return 1
    last_number, last = attempts[-1]
    statuses = [record.get("status") for _, record in attempts]
    if statuses[-1] in ("saved", "bound_by_other"):
        return None
    allowed = {"starting", "pre_send_failed", "send_intent_recorded",
               "sent_waiting_for_image", "send_unverified", "failed"}
    if any(status not in allowed and status not in ("saved", "bound_by_other")
           for status in statuses):
        return None
    if any(status in ("saved", "bound_by_other") for status in statuses):
        return None
    pre_send_count = sum(status == "pre_send_failed" for status in statuses)
    send_count = sum(status != "pre_send_failed" for status in statuses)
    if pre_send_count >= MAX_PRE_SEND_FAILURES and last.get("status") == "pre_send_failed":
        return None
    if send_count >= MAX_PROTOCOL_ATTEMPTS:
        return None
    try:
        stamp = datetime.fromisoformat(last["at"])
        if stamp.tzinfo is None or (now - stamp).total_seconds() < COOLDOWN_SECONDS:
            return None
    except (ValueError, TypeError, KeyError):
        return None
    return last_number + 1



def publish_image_retry_summary(api, auth, job):
    """Publish only bounded, revision-verified counters, never local journal data."""
    import image_retry_status_v2 as status_module
    tid, rev = job["trend_id"], job["revision"]
    records = []
    for path in JOURNALS.glob("%s-r%d-attempt-*.json" % (tid, rev)):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if data.get("trend_id") != tid or data.get("revision") != rev:
                return False
            data["attempt"] = int(path.stem.rsplit("-", 1)[1])
            records.append(data)
        except (ValueError, KeyError, json.JSONDecodeError, OSError):
            return False
    if not records:
        return False
    summary = status_module.retry_status(records)
    public = {"revision": rev, "editorial_sha256": job["editorial_sha256"],
              "state": summary["state"],
              "send_attempts": summary["send_attempts"],
              "send_limit": summary["send_limit"],
              "pre_send_failures": summary["pre_send_failures"],
              "pre_send_limit": summary["pre_send_limit"]}
    for retry in range(4):
        queue, sha = editorial.queue_read(api, auth)
        row = (queue.get("items") or {}).get(tid) or {}
        cap = row.get("capture") or {}
        if (row.get("revision") != rev or cap.get("revision") != rev
            or cap.get("sha256") != job["editorial_sha256"]):
            return False
        if row.get("image_retry_summary") == public:
            return True
        row["image_retry_summary"] = public
        try:
            editorial.queue_write(api, auth, sha, queue, "image retry summary " + tid)
            return True
        except RuntimeError as exc:
            if "GitHub conflict/changed revision" not in str(exc) or retry == 3:
                raise
            time.sleep(retry + 1)
    return False


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


def submit_image_prompt(page, composer, prompt, command_id, *, before_click=None):
    """Send once through ChatGPT's enabled send button if available.

    A Playwright click/keypress is only an intent. The tracker must still
    verify the exact user turn before the image is accepted.
    """
    composer.fill(prompt)
    try:
        entered = composer.input_value(timeout=3000)
    except Exception:
        entered = composer.text_content(timeout=3000) or ""
    if command_id not in entered:
        raise RuntimeError("V2_IMAGE_PROMPT_NOT_IN_COMPOSER")
    found_send_button = False
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        for selector in SEND_BUTTONS:
            button = page.locator(selector).first
            if button.count() and button.is_visible():
                found_send_button = True
                if button.is_enabled() and button.get_attribute("aria-disabled") != "true":
                    # Persist the send intent only when an enabled control exists.
                    # If interrupted after this point, the attempt remains ambiguous.
                    if before_click is not None:
                        before_click()
                    button.click(timeout=10000)
                    return "send_button"
        # React may mount or enable the send button after filling the editor.
        # Do not treat its absence on the first poll as definitive.
        time.sleep(0.5)
    if found_send_button:
        raise RuntimeError("V2_IMAGE_SEND_BUTTON_DISABLED")
    # Never use Enter as an unverified fallback: in some ChatGPT composer
    # states it leaves the command unsent and wastes image attempts.
    raise RuntimeError("V2_IMAGE_SEND_BUTTON_UNAVAILABLE")


def run_one(row, attempt, *, api, auth):
    """Isolated lifecycle, safe even while editorial Chrome is running."""
    tid, rev = row["trend_id"], row["revision"]
    # The job is immutable for this attempt. Its destination chat URL will be
    # updated only after ChatGPT's new conversation is proven to contain it.
    job = jobs.proposed_job(row, attempt=attempt,
                            nonce=secrets.token_hex(12))
    try:
        if image_profile_pids():
            raise RuntimeError("V2_IMAGE_OWN_PROFILE_ALREADY_RUNNING")
        if not CHROME.exists():
            raise RuntimeError("V2_IMAGE_CHROME_NOT_FOUND")
        if not PROFILE.is_dir():
            raise RuntimeError("V2_IMAGE_PROFILE_LOGIN_REQUIRED")
        if journal_path(tid, rev, attempt).exists():
            raise RuntimeError("V2_IMAGE_ATTEMPT_ALREADY_RECORDED_NO_RESEND")
    except Exception as exc:
        # Preserve the preflight/journal retry contract: reporting creates no
        # journal, no send intent, no Chrome and no additional attempt.
        record_image_failure(api, auth, job, exc)
        raise
    github.current_editorial(job, auth)
    JOURNALS.mkdir(parents=True, exist_ok=True)
    journal = journal_path(tid, rev, attempt)
    record = {"at": datetime.now(timezone.utc).isoformat(),
              "trend_id": tid, "revision": rev, "attempt": attempt,
              "command_id": job["command_id"], "status": "starting",
              "send_protocol": IMAGE_SEND_PROTOCOL,
              "publication_allowed": False}
    editorial.store(journal, record)
    process = None
    browser = None
    hider = None
    progress_registered = False
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
            try:
                progress_registered = update_image_progress(api, auth, job, active=True)
                if progress_registered:
                    record["image_progress_projection"] = sync_image_progress(auth)
                editorial.store(journal, record)
            except Exception as exc:
                # A UI indicator must never block actual ImageGen work.
                record["image_progress_projection"] = "unavailable:" + type(exc).__name__
                editorial.store(journal, record)
            # An attempt may be repeated in a NEW chat after a timeout.
            # Do not send this same attempt twice if the process is interrupted.
            def record_send_intent():
                record["status"] = "send_intent_recorded"
                editorial.store(journal, record)

            record["send_trigger"] = submit_image_prompt(
                page, composer, job["prompt"], job["command_id"],
                before_click=record_send_intent)
            record["status"] = "sent_waiting_for_image"
            record["immediate_observation"] = tracker.submission_observation(
                page, job["command_id"])
            editorial.store(journal, record)
            submitted_page = page
            page, discovery = tracker.await_image_conversation(
                browser, page, job["command_id"], seconds=150,
                baseline_urls=baseline)
            record["chat_discovery"] = discovery
            record["browser_diagnostics"] = tracker.browser_diagnostics(
                browser, submitted_page)
            record["submission_observation"] = tracker.submission_observation(
                submitted_page, job["command_id"])
            editorial.store(journal, record)
            if page is None:
                if record["submission_observation"].get("composer_contains_command") is True:
                    raise RuntimeError("V2_IMAGE_PROMPT_NOT_SUBMITTED")
                raise RuntimeError("V2_IMAGE_SEND_UNVERIFIED_NO_RESEND")
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
                       ("sha256", "path", "mime", "revision", "backend", "command_id", "attempt")}
            receipt["status"] = "saved"
            receipt["image_chat_url"] = url
            editorial.update_image_receipt(api, auth, tid, rev, job["editorial_sha256"], receipt)
            verified, _ = editorial.queue_read(api, auth)
            bound = ((verified["items"].get(tid) or {}).get("capture") or {}).get("image") or {}
            if bound.get("status") != "saved":
                raise RuntimeError("V2_IMAGE_QUEUE_RECEIPT_NOT_SAVED")
            record["status"] = ("saved" if (bound.get("sha256") == saved["sha256"]
                                                  and bound.get("path") == saved["path"])
                                else "bound_by_other")
            if record["status"] == "saved":
                try:
                    record["superseded_images_deleted"] = github.cleanup_superseded_images(
                        tid, saved["path"], auth)
                except Exception as exc:
                    # The new image is already verified; cleanup can be retried
                    # without invalidating the current image receipt.
                    record["legacy_image_cleanup"] = "pending:" + type(exc).__name__
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
        # If submission or capture was uncertain, the next bounded attempt
        # uses a new chat and command; the latest successful raster replaces the old one.
        if (record.get("status") == "starting"
                and str(exc) in ("V2_IMAGE_SEND_BUTTON_UNAVAILABLE",
                                 "V2_IMAGE_SEND_BUTTON_DISABLED",
                                 "V2_IMAGE_PROMPT_NOT_IN_COMPOSER")):
            record["status"] = "pre_send_failed"
        else:
            record["status"] = ("send_unverified" if str(exc) ==
                                "V2_IMAGE_SEND_UNVERIFIED_NO_RESEND" else "failed")
        record["error"] = str(exc)[:250]
        editorial.store(journal, record)
        record_image_failure(api, auth, job, exc, journal=journal, record=record)
        raise
    finally:
        if progress_registered:
            try:
                if update_image_progress(api, auth, job, active=False):
                    record["image_progress_cleared"] = sync_image_progress(auth)
                    editorial.store(journal, record)
            except Exception as exc:
                record["image_progress_cleared"] = "retry_later:" + type(exc).__name__
                editorial.store(journal, record)
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
        try:
            if publish_image_retry_summary(api, auth, job):
                sync_image_progress(auth)
        except Exception as exc:
            print("TT_V2_IMAGE_RETRY_SUMMARY=DEGRADED:" + type(exc).__name__, flush=True)



def backfill_retry_summaries(api, auth, *, dry_run=True):
    """Bulk backfill from existing local journals; never opens Chrome or sends."""
    queue, _ = editorial.queue_read(api, auth)
    candidates = []
    for tid, row in (queue.get("items") or {}).items():
        cap = row.get("capture") or {}
        rev = row.get("revision")
        if (not isinstance(rev, int) or rev < 1
            or row.get("status") not in ("captured_review", "ready")
            or cap.get("revision") != rev
            or not re.fullmatch(r"[a-f0-9]{64}", str(cap.get("sha256", "")))
            or not re.fullmatch(r"trv2-[a-f0-9]{24}", str(tid))
            or not any(JOURNALS.glob("%s-r%d-attempt-*.json" % (tid, rev)))):
            continue
        candidates.append({"trend_id": tid, "revision": rev,
                           "editorial_sha256": cap["sha256"]})
    print("TT_V2_IMAGE_BACKFILL_CANDIDATES=" + str(len(candidates)), flush=True)
    if dry_run:
        print("TT_V2_IMAGE_BACKFILL_DRY_RUN=YES", flush=True)
        return
    updated = 0
    for job in candidates:
        if publish_image_retry_summary(api, auth, job):
            updated += 1
    print("TT_V2_IMAGE_BACKFILL_UPDATED=" + str(updated), flush=True)
    print("TT_V2_IMAGE_BACKFILL_WEB=" + sync_image_progress(auth), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backfill-retry-status", action="store_true",
                        help="Bulk sync safe retry summaries from local journals; no images")
    parser.add_argument("--apply", action="store_true",
                        help="Write bulk retry summaries; without this flag, dry-run")
    parser.add_argument("--run-one", action="store_true",
                        help="Generate one image on a separate ChatGPT conversation")
    parser.add_argument("--trend-id", help="ID reservado por el despachador paralelo")
    parser.add_argument("--revision", type=int)
    parser.add_argument("--attempt", type=int)
    args = parser.parse_args()
    api = editorial.module("persist_capture_github.py", "ttv2_image_github_api")
    auth = api.token()
    if args.backfill_retry_status:
        if args.run_one or args.trend_id or args.revision or args.attempt:
            raise RuntimeError("V2_IMAGE_BACKFILL_FLAGS_CONFLICT")
        backfill_retry_summaries(api, auth, dry_run=not args.apply)
        return
    if args.apply:
        raise RuntimeError("V2_IMAGE_APPLY_ONLY_WITH_BACKFILL")
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

