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


def observe_probe(browser):
    """Read only the exact probe user turn in one of our Chrome pages.

    The home composer can navigate into a new tab. Following the Trends V2
    approach, do not assume the original home Page is the eventual chat.
    """
    matches = {}
    for context in browser.browser.contexts:
        for page in context.pages:
            try:
                url = page.url.split('?', 1)[0].split('#', 1)[0]
                if not CHAT.fullmatch(url):
                    continue
                users, answers = read_news_turns(page)
                if len(users) != 1 or users[0].strip() != PROBE:
                    continue
                matches[url] = (answers, page.locator(STOP).count() > 0)
            except Exception:
                continue
    if len(matches) != 1:
        return {"submission_confirmed": False, "assistant_turns": 0,
                "response_seen": False, "probe_ok": False, "stop_visible": False}
    answers, stop_visible = next(iter(matches.values()))
    answer = answers[-1].strip() if answers else ''
    return {"submission_confirmed": True, "assistant_turns": len(answers),
            "response_seen": bool(answer), "probe_ok": "TTN2_PROBE_OK" in answer,
            "stop_visible": stop_visible}


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
