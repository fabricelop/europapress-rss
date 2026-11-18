"""Read-only inspection of one already submitted News V2 chat.

Prints counts and marker flags only. It never sends or persists a news result.
"""
from __future__ import annotations

import argparse
import json as json_parser
import json
from pathlib import Path
import time
import uuid

from v2.ttittulares.editorial_browser_v2 import ChromeJob, CHAT, STOP, fresh_turn, read_news_turns
from v2.ttittulares.editorial_consumer_v2 import settings


def inspect(root: Path, run_id: str) -> dict:
    config = settings(root)
    journal_path = config["root"] / "journals" / (run_id + ".json")
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    if journal.get("run_id") != run_id or journal.get("submission_confirmed") is not True:
        raise RuntimeError("NEWS_DIAGNOSTIC_JOURNAL_NOT_CONFIRMED")
    chat_url = journal.get("chat_url")
    if not isinstance(chat_url, str) or not CHAT.fullmatch(chat_url):
        raise RuntimeError("NEWS_DIAGNOSTIC_CHAT_URL_INVALID")
    profile = config["root"] / "sessions" / uuid.uuid4().hex / "Profile"
    browser = ChromeJob(chrome=config["chrome"], seed=config["seed"], profile=profile, timeout=90)
    result = {"job_id": journal.get("job_id"), "revision": journal.get("revision"),
              "sent": journal.get("sent"), "submission_confirmed": True}
    try:
        browser.open()
        browser.page.goto(chat_url, wait_until="domcontentloaded", timeout=60000)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            users, answers = read_news_turns(browser.page)
            body = browser.page.locator("body").inner_text(timeout=4500)
            result.update(
                exact_identity=fresh_turn(users, journal["event_id"], journal["revision"], journal["command_id"]),
                user_turns=len(users), assistant_turns=len(answers),
                answer_chars=len(answers[-1]) if answers else 0,
                answer_begin=bool(answers and "TTN2_EDITORIAL_BEGIN" in answers[-1]),
                answer_end=bool(answers and "TTN2_EDITORIAL_END" in answers[-1]),
                body_begin_count=body.count("TTN2_EDITORIAL_BEGIN"),
                body_end_count=body.count("TTN2_EDITORIAL_END"),
                body_chars=len(body),
                stop_visible=browser.page.locator(STOP).count() > 0,
                same_chat=browser.page.url.split("?", 1)[0].rstrip("/") == chat_url.rstrip("/"),
            )
            last_begin = body.rfind("TTN2_EDITORIAL_BEGIN")
            tail = body[last_begin + len("TTN2_EDITORIAL_BEGIN"):].strip() if last_begin >= 0 else ""
            decoder = json_parser.JSONDecoder()
            try:
                payload, consumed = decoder.raw_decode(tail)
                result["last_begin_json_complete"] = isinstance(payload, dict)
                result["last_begin_json_event_id_matches"] = isinstance(payload, dict) and payload.get("event_id") == journal["event_id"]
                result["last_begin_json_revision_matches"] = isinstance(payload, dict) and payload.get("revision") == journal["revision"]
                result["last_begin_json_command_matches"] = isinstance(payload, dict) and payload.get("command_id") == journal["command_id"]
                result["last_begin_trailing_chars"] = len(tail[consumed:].strip())
            except (ValueError, TypeError):
                result["last_begin_json_complete"] = False
                result["last_begin_json_event_id_matches"] = False
                result["last_begin_json_revision_matches"] = False
                result["last_begin_json_command_matches"] = False
                result["last_begin_trailing_chars"] = None
            result["last_begin_tail_chars"] = len(tail)
            if result["assistant_turns"] and not result["stop_visible"]:
                break
            time.sleep(3)
    finally:
        browser.close()
        result["cleanup_verified"] = browser.cleanup_verified
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    if len(args.run_id) != 32 or any(c not in "0123456789abcdef" for c in args.run_id):
        parser.error("run-id must be a lowercase 32-character UUID")
    print(json.dumps(inspect(args.root, args.run_id), ensure_ascii=False))


if __name__ == "__main__":
    main()
