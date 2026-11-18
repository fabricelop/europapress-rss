"""One isolated ChatGPT response probe for the News V2 Chrome profile.

Does not claim a news job, write queues, or publish. Sends one harmless probe,
then closes and removes only its disposable Chrome profile.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import time
import uuid

from v2.ttittulares.editorial_browser_v2 import CHAT, ChromeJob, STOP, read_news_turns
from v2.ttittulares.editorial_consumer_v2 import settings

PROBE = "Prueba de funcionamiento de Noticias V2. Responde exactamente: TTN2_PROBE_OK"


def probe_user_matches(value):
    """Allow UI-injected whitespace and short button labels in a user bubble."""
    if not isinstance(value, str):
        return False
    text = ' '.join(value.split())
    return text.startswith(PROBE) and len(text) <= len(PROBE) + 100


def observe_probe(browser):
    """Read only the exact probe user turn in one of our Chrome pages.

    The home composer can navigate into a new tab. Following the Trends V2
    approach, do not assume the original home Page is the eventual chat.
    """
    matches = {}
    counts = {"owned_pages_seen": 0, "chat_pages_seen": 0,
              "user_turn_pages": 0, "probe_user_pages": 0,
              "assistant_pages_seen": 0, "probe_reply_without_chat_url": False}
    for context in browser.browser.contexts:
        for page in context.pages:
            try:
                counts["owned_pages_seen"] += 1
                url = page.url.split('?', 1)[0].split('#', 1)[0]
                is_chat = bool(CHAT.fullmatch(url))
                counts["chat_pages_seen"] += int(is_chat)
                users, answers = read_news_turns(page)
                counts["user_turn_pages"] += int(bool(users))
                counts["assistant_pages_seen"] += int(bool(answers))
                matches_prompt = len(users) == 1 and probe_user_matches(users[0])
                counts["probe_user_pages"] += int(matches_prompt)
                if matches_prompt and not is_chat and answers:
                    counts["probe_reply_without_chat_url"] = True
                if not (is_chat and matches_prompt):
                    continue
                matches[url] = (answers, page.locator(STOP).count() > 0)
            except Exception:
                continue
    if len(matches) != 1:
        return {"submission_confirmed": False, "assistant_turns": 0,
                "response_seen": False, "probe_ok": False, "stop_visible": False,
                **counts}
    answers, stop_visible = next(iter(matches.values()))
    answer = answers[-1].strip() if answers else ''
    return {"submission_confirmed": True, "assistant_turns": len(answers),
            "response_seen": bool(answer), "probe_ok": "TTN2_PROBE_OK" in answer,
            "stop_visible": stop_visible, **counts}


def run(root: Path):
    config = settings(root)
    profile = config["root"] / "sessions" / uuid.uuid4().hex / "Profile"
    browser = ChromeJob(chrome=config["chrome"], seed=config["seed"], profile=profile, timeout=90)
    result = {"probe_sent": False, "submission_confirmed": False,
              "response_seen": False, "probe_ok": False, "assistant_turns": 0,
              "stop_visible": False, "cleanup_verified": False}
    try:
        browser.open()
        browser.send_once(PROBE)
        result["probe_sent"] = True
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            result.update(observe_probe(browser))
            if result["probe_ok"] and not result["stop_visible"]:
                break
            time.sleep(2)
    finally:
        browser.close()
        result["cleanup_verified"] = browser.cleanup_verified
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.root)))


if __name__ == "__main__":
    main()
