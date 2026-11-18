"""Inspect an existing News V2 ChatGPT chat without sending any message.

Only aggregate DOM/visible-text signals are returned. Never print the chat
URL, transcript, credentials, profile path, or user-supplied content.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import time
import uuid
from urllib.parse import urlsplit

from .editorial_browser_v2 import CHAT, ChromeJob, STOP, read_news_turns
from .editorial_consumer_v2 import settings


def validated_chat_url(value):
    if not isinstance(value, str) or len(value) > 2048:
        raise RuntimeError('NEWS_PROBE_CHAT_URL_INVALID')
    try:
        parsed = urlsplit(value.strip())
        url = parsed.scheme + '://' + parsed.netloc + parsed.path.rstrip('/')
    except ValueError:
        raise RuntimeError('NEWS_PROBE_CHAT_URL_INVALID') from None
    if parsed.username or parsed.password or not CHAT.fullmatch(url):
        raise RuntimeError('NEWS_PROBE_CHAT_URL_INVALID')
    return url


def _contents(page, selector):
    try:
        return page.locator(selector).all_text_contents(timeout=4500)
    except Exception:
        return []


def _count(page, selector):
    try:
        return page.locator(selector).count()
    except Exception:
        return -1


def inspect_chat(page):
    """Role counts and marker counts only; no transcript or URL in output."""
    user_role = '[data-message-author-role="user"]'
    assistant_role = '[data-message-author-role="assistant"]'
    users = _contents(page, user_role)
    assistants = _contents(page, assistant_role)
    markdown = _contents(page, assistant_role + ' .markdown')
    try:
        body = page.locator('body').inner_text(timeout=4500)
    except Exception:
        body = ''
    try:
        extracted_users, extracted_answers = read_news_turns(page)
    except Exception:
        extracted_users, extracted_answers = [], []
    return {
        'chat_route': bool(CHAT.fullmatch(page.url.split('?', 1)[0].split('#', 1)[0])),
        'user_role_nodes': _count(page, user_role),
        'assistant_role_nodes': _count(page, assistant_role),
        'user_role_nonempty': sum(bool(s.strip()) for s in users),
        'assistant_role_nonempty': sum(bool(s.strip()) for s in assistants),
        'assistant_markdown_nodes': _count(page, assistant_role + ' .markdown'),
        'assistant_markdown_nonempty': sum(bool(s.strip()) for s in markdown),
        'any_markdown_nodes': _count(page, '.markdown'),
        'visible_user_labels': len(re.findall(r'(?m)^\s*(?:You said|Tú dijiste|Has dicho):\s*$', body)),
        'visible_assistant_labels': len(re.findall(r'(?m)^\s*(?:ChatGPT said|ChatGPT dijo|ChatGPT respondió|ChatGPT ha dicho):\s*$', body)),
        'blocked_marker_occurrences': body.count('TTN2_EDITORIAL_BLOCKED'),
        'extracted_user_turns': len(extracted_users),
        'extracted_assistant_turns': len(extracted_answers),
        'stop_visible': _count(page, STOP) > 0,
    }


def run(root, target):
    url = validated_chat_url(target)
    config = settings(root)
    flag = config['root'] / 'editorial.enabled'
    if not flag.is_file() or flag.read_text(encoding='utf-8').strip() != 'TTN2_EDITORIAL_ENABLED=NO':
        raise RuntimeError('NEWS_EDITORIAL_MUST_REMAIN_DISABLED')
    profile = config['root'] / 'sessions' / uuid.uuid4().hex / 'Profile'
    browser = ChromeJob(chrome=config['chrome'], seed=config['seed'], profile=profile)
    result = {'opened_existing_chat': False, 'message_sent': False,
              'published': False, 'cleanup_verified': False}
    try:
        browser.open()
        browser.page.goto(url, wait_until='domcontentloaded', timeout=60000)
        result['opened_existing_chat'] = True
        previous, stable = None, 0
        until = time.monotonic() + 45
        while time.monotonic() < until:
            current = inspect_chat(browser.page)
            stable = stable + 1 if current == previous else 0
            previous = current
            if stable >= 2 and (current['assistant_role_nonempty']
                                or current['assistant_markdown_nonempty']
                                or current['extracted_assistant_turns']):
                break
            time.sleep(2)
        result.update(previous or {})
    finally:
        browser.close()
        result['cleanup_verified'] = browser.cleanup_verified
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--url', required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.root, args.url), sort_keys=True))


if __name__ == '__main__':
    main()
