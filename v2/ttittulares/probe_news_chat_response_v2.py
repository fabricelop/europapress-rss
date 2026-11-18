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

from v2.ttittulares.editorial_browser_v2 import ChromeJob, STOP, read_news_turns
from v2.ttittulares.editorial_consumer_v2 import settings

PROBE = "Prueba de funcionamiento de Noticias V2. Responde exactamente: TTN2_PROBE_OK"


def run(root: Path):
    config = settings(root)
    profile = config["root"] / "sessions" / uuid.uuid4().hex / "Profile"
    browser = ChromeJob(chrome=config["chrome"], seed=config["seed"], profile=profile, timeout=90)
    result = {"probe_sent": False, "response_seen": False, "probe_ok": False,
              "assistant_turns": 0, "stop_visible": False, "cleanup_verified": False}
    try:
        browser.open()
        browser.send_once(PROBE)
        result["probe_sent"] = True
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            users, answers = read_news_turns(browser.page)
            result["assistant_turns"] = len(answers)
            result["response_seen"] = bool(answers)
            result["probe_ok"] = bool(answers and "TTN2_PROBE_OK" in answers[-1])
            result["stop_visible"] = browser.page.locator(STOP).count() > 0
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
