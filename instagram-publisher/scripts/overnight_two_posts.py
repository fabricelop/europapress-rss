#!/usr/bin/env python3
"""Two explicitly authorized Instagram posts; bounded one-night retries.

Never select other editorial items; never bypass the publisher's D1 idempotency.
No request after 09 Oct 2026 08:30 Europe/Madrid.
"""
import datetime
import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "overnight-status.json"
SERVICE = "https://tt-actualidad-instagram-pilot.fabricelop.workers.dev"
RAW = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
DAY = datetime.date(2026, 10, 9)
ZONE = ZoneInfo("Europe/Madrid")
MAX_ATTEMPTS = 18
TARGETS = (
    {"source": "ttendencias", "event_id": "3ff255e46d90", "revision": 1,
     "telegram_message_id": 391, "delivery": "trends/telegram-image-deliveries.json",
     "image_url": RAW + "trends/instagram-images/ig-3ff255e46d90-r1-3efa0c8a287a.jpg",
     "token_env": "TTENDENCIAS_BOT_TOKEN", "chat_env": ""},
    {"source": "ttittulares", "event_id": "1dc952e6340e", "revision": 1,
     "telegram_message_id": 3105, "delivery": "telegram/ttittulares-deliveries.json",
     "image_url": RAW + "ttittulares/instagram-images/ig-1dc952e6340e-r1-2d9b8fae4f17.jpg",
     "token_env": "TELEGRAM_BOT_TOKEN", "chat_env": "TELEGRAM_CHAT_ID"},
)
FINAL = {"published", "blocked", "exhausted"}
RETRYABLE_CODES = {
    "CONTAINER_CREATION_FAILED", "STATUS_CHECK_FAILED", "CONTAINER_NOT_READY",
    "BUSY", "NON_JSON_RESPONSE", "NETWORK_FAILURE", "TIMEOUT",
}
BLOCK_CODES = {
    "NEEDS_RECONCILIATION", "SELECTION_CHANGED", "UNAUTHORIZED",
    "PILOT_DISABLED", "NOT_CONFIGURED", "MISSING_REQUIRED_BINDINGS",
    "INVALID_REQUEST", "INTERNAL_ERROR",
}


def now_madrid():
    return datetime.datetime.now(ZONE)


def may_run(now):
    return now.date() == DAY and now.time() < datetime.time(8, 30)


def request(url, *, body=None, token=None, timeout=75):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    headers = {"user-agent": "ttactualidad-two-posts-overnight-20261009"}
    if data is not None:
        headers["content-type"] = "application/json"
    if token:
        headers["authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            code = int(response.status)
            raw = response.read(32768)
    except urllib.error.HTTPError as exc:
        code = int(exc.code)
        raw = exc.read(32768)
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        kind = "TIMEOUT" if "timed out" in str(exc).lower() else "NETWORK_FAILURE"
        return 0, {"ok": False, "error": kind}
    try:
        doc = json.loads(raw.decode("utf-8"))
        if not isinstance(doc, dict):
            raise ValueError("Not a JSON object")
        return code, doc
    except (ValueError, UnicodeError):
        return code, {"ok": False, "error": "NON_JSON_RESPONSE"}


def get_json(url):
    code, value = request(url, timeout=30)
    if code != 200 or not isinstance(value, dict):
        raise RuntimeError("PACKAGE_FETCH_FAILURE_" + str(code))
    return value


def payload_for(target):
    # Source-of-truth is the exact delivery the user approved; don't rewrite a post.
    doc = get_json(RAW + target["delivery"])
    matches = [row for row in doc.get("items", [])
               if row.get("event_id") == target["event_id"]
               and row.get("revision") == target["revision"]
               and row.get("telegram_message_id") == target["telegram_message_id"]]
    if len(matches) != 1:
        raise RuntimeError("DELIVERY_IDENTITY_NOT_UNIQUE")
    row = matches[0]
    ig = row.get("instagram") or {}
    if row.get("status") != "sent" or ig.get("image_url") != target["image_url"]:
        raise RuntimeError("DELIVERY_CHANGED")
    caption = str(ig.get("caption") or "")
    if not caption.strip() or len(caption) > 2200:
        raise RuntimeError("CAPTION_INVALID")
    return {"source": target["source"], "event_id": target["event_id"],
            "revision": target["revision"],
            "telegram_message_id": target["telegram_message_id"],
            "image_url": target["image_url"], "caption": caption}


def classify(code, body):
    state = str(body.get("state") or "")
    error = str(body.get("error") or "")
    if state == "published" and body.get("media_id"):
        return "published"
    if state == "uncertain" or state in {"creating", "publishing"}:
        return "blocked"
    if error in BLOCK_CODES:
        return "blocked"
    if state == "processing" or error in RETRYABLE_CODES:
        return "retryable"
    if code == 202 or code in {429, 500, 502, 503, 504}:
        return "retryable"
    return "blocked"


def send_notification(target, permalink):
    token = os.environ.get(target["token_env"], "")
    if target["chat_env"]:
        chat = os.environ.get(target["chat_env"], "")
    else:
        chat = str(get_json(RAW + "trends/telegram-bot-state.json").get("chat_id") or "")
    if not token or not chat:
        return False
    label = "Shakira / #LaRevuelta" if target["source"] == "ttendencias" else "Real Madrid / Euroliga"
    message = "Instagram: publicación confirmada de " + label
    if isinstance(permalink, str) and permalink.startswith("https://www.instagram.com/"):
        message += "\n" + permalink
    url = "https://api.telegram.org/bot" + token + "/sendMessage"
    body = {"chat_id": chat, "text": message,
            "reply_to_message_id": target["telegram_message_id"]}
    # Telegram Bot API does not use Bearer authorization.
    for attempt in range(2):
        data = json.dumps(body, ensure_ascii=False).encode()
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                if json.loads(resp.read().decode()).get("ok"):
                    return True
        except (urllib.error.HTTPError, urllib.error.URLError, OSError, ValueError):
            pass
        body.pop("reply_to_message_id", None)
    return False


def run():
    stamp = now_madrid()
    report = json.loads(REPORT.read_text("utf-8")) if REPORT.exists() else {
        "version": 1, "authorized_night": str(DAY), "targets": {}
    }
    report.setdefault("targets", {})
    can_run = may_run(stamp)
    secret = os.environ.get("INSTAGRAM_INTERNAL_SECRET", "")
    for target in TARGETS:
        key = target["source"] + ":" + target["event_id"]
        entry = report["targets"].setdefault(key, {
            "status": "pending", "attempts": 0, "notified": False
        })
        if entry["status"] == "published":
            if not entry.get("notified") and can_run:
                entry["notified"] = send_notification(target, entry.get("permalink", ""))
            continue
        if entry["status"] in FINAL or not can_run:
            continue
        if entry["attempts"] >= MAX_ATTEMPTS:
            entry["status"] = "exhausted"
            continue
        entry["attempts"] += 1
        entry["last_checked_at"] = stamp.isoformat(timespec="seconds")
        if len(secret) < 32:
            entry.update({"status": "blocked", "error": "MISSING_GITHUB_SECRET"})
            continue
        try:
            post = payload_for(target)
            code, answer = request(SERVICE + "/publish", body=post, token=secret)
            entry["http_status"] = code
            entry["publisher_state"] = str(answer.get("state") or "")[:48]
            entry["error"] = str(answer.get("error") or "")[:80]
            entry["status"] = classify(code, answer)
            if entry["status"] == "published":
                entry["media_id"] = str(answer.get("media_id") or "")[:64]
                entry["permalink"] = str(answer.get("permalink") or "")[:200]
                entry["notified"] = send_notification(target, entry.get("permalink", ""))
            if entry["status"] == "retryable" and entry["attempts"] >= MAX_ATTEMPTS:
                entry["status"] = "exhausted"
        except Exception as exc:
            entry["status"] = "retryable" if entry["attempts"] < MAX_ATTEMPTS else "exhausted"
            entry["error"] = type(exc).__name__ + "_" + str(exc)[:80]
        # Never hammer Meta or Telegram; next scheduled tick handles retries.
        time.sleep(1)
    if not can_run:
        report["closed_at"] = stamp.isoformat(timespec="seconds")
    report["updated_at"] = stamp.isoformat(timespec="seconds")
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", "utf-8")
    done = not can_run or all(
        report["targets"].get(t["source"] + ":" + t["event_id"], {}).get("status") in FINAL
        for t in TARGETS
    )
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf8") as fd:
            fd.write("should_disable=" + ("true" if done else "false") + "\n")
    for target in TARGETS:
        key = target["source"] + ":" + target["event_id"]
        e = report["targets"].get(key, {})
        print("OVERNIGHT_INSTAGRAM", key, e.get("status"), e.get("error", ""),
              "http=" + str(e.get("http_status", "")),
              "attempts=" + str(e.get("attempts", 0)))
    print("OVERNIGHT_DONE=" + str(done))


def selftest():
    assert len(TARGETS) == 2
    assert len({(x["source"], x["event_id"]) for x in TARGETS}) == 2
    assert all(x["image_url"].startswith(RAW) for x in TARGETS)
    assert not may_run(datetime.datetime(2026, 10, 9, 8, 31, tzinfo=ZONE))
    assert may_run(datetime.datetime(2026, 10, 9, 2, 0, tzinfo=ZONE))
    assert classify(200, {"state":"published","media_id":"123"}) == "published"
    assert classify(409, {"state":"creating","error":"NEEDS_RECONCILIATION"}) == "blocked"
    assert classify(503, {"state":"uncertain"}) == "blocked"
    assert classify(502, {"error":"CONTAINER_CREATION_FAILED"}) == "retryable"
    assert classify(202, {"state":"processing"}) == "retryable"
    assert classify(0, {"error":"TIMEOUT"}) == "retryable"
    assert classify(401, {"error":"UNAUTHORIZED"}) == "blocked"
    print("OVERNIGHT_TWO_APPROVED_POSTS_TESTS_OK")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        selftest()
    else:
        run()
