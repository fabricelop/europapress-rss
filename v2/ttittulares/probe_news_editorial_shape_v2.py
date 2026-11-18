"""Probe the News V2 editorial prompt without touching the news queue."""
import argparse
import json
from pathlib import Path
import time
import uuid
from v2.ttittulares.editorial_browser_v2 import ChromeJob, STOP, read_news_turns
from v2.ttittulares.editorial_consumer_v2 import settings
from v2.ttittulares.editorial_contract_v2 import build_prompt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    config = settings(args.root)
    ident = "ttn2-0123456789abcdef01234567"
    news = {"schema_version": 1, "project": "ttittulares-v2", "event_id": ident,
            "current_revision": 1, "status": "editorial_pending",
            "identity": {"canonical_title": "Prueba sin acontecimiento real"},
            "source_context": {"canonical_urls": [], "source_families": []}}
    job = {"schema_version": 1, "project": "ttittulares-v2", "event_id": ident,
           "revision": 1, "job_id": ident + "-r1-editorial", "status": "claimed",
           "requested_at": "2026-11-18T00:00:00Z"}
    prompt = build_prompt(news, job, "news-probe-no-queue")
    profile = config["root"] / "sessions" / uuid.uuid4().hex / "Profile"
    browser = ChromeJob(chrome=config["chrome"], seed=config["seed"], profile=profile)
    report = {"prompt_chars": len(prompt), "probe_sent": False,
              "submission_confirmed": False, "assistant_turns": 0,
              "response_seen": False, "stop_visible": False, "cleanup_verified": False}
    try:
        browser.open()
        browser.send_once(prompt)
        report["probe_sent"] = True
        # Just like the production consumer, bind the exact submitted user
        # turn first: ChatGPT can move the conversation to another owned tab.
        # Inspecting only the original home tab yields a false "no reply".
        browser.confirm_submission(ident, 1, "news-probe-no-queue")
        report["submission_confirmed"] = True
        until = time.monotonic() + 300
        while time.monotonic() < until:
            users, answers = read_news_turns(browser.page)
            report["assistant_turns"] = len(answers)
            report["response_seen"] = bool(answers and answers[-1].strip())
            report["stop_visible"] = browser.page.locator(STOP).count() > 0
            if report["response_seen"] and not report["stop_visible"]:
                break
            time.sleep(2)
    finally:
        browser.close()
        report["cleanup_verified"] = browser.cleanup_verified
    print(json.dumps(report))


if __name__ == "__main__":
    main()
