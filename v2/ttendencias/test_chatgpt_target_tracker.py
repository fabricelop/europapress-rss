#!/usr/bin/env python3
"""Pruebas puras del descubridor CDP, sin Chrome ni red."""
import unittest
from unittest.mock import patch
import chatgpt_target_tracker as tracker

TREND = "trv2-2597e98b6da6659ce2710a57"
URL = "https://chatgpt.com/c/6af706c8-97d8-83eb-b7e3-ba3d1d0d0de1"

class Locator:
    def __init__(self, body): self.body = body
    def inner_text(self, timeout=4500): return self.body

class Page:
    def __init__(self, url, body):
        self.url = url
        self.body = body
    def locator(self, selector): return Locator(self.body)

class Context:
    def __init__(self, pages): self.pages = pages

class CDP:
    def __init__(self, urls): self.urls = urls
    def send(self, operation):
        assert operation == "Target.getTargets"
        return {"targetInfos": [{"type":"page","url":u} for u in self.urls]}
    def detach(self): pass

class Browser:
    def __init__(self, pages, urls):
        self.contexts = [Context(pages)]
        self.urls = urls
    def new_browser_cdp_session(self): return CDP(self.urls)

class TargetTests(unittest.TestCase):
    def test_canonical(self):
        self.assertEqual(tracker.canonical(URL + "?foo=bar"), URL)

    def test_cdp_discovers_unattached_target(self):
        browser = Browser([Page("https://chatgpt.com/", "")], [URL])
        self.assertEqual(tracker.conversation_urls(browser), [URL])

    def test_reject_foreign_and_root_urls(self):
        browser = Browser([], ["https://chatgpt.com/", "https://example.org/c/foo", URL])
        self.assertEqual(tracker.conversation_urls(browser), [URL])

    def test_identity_correct(self):
        body = ("ChatGPT\nYou said:\nIdentificador: " + TREND +
                ". Revisión: 1.\nChatGPT said:\nTexto editorial verificado")
        self.assertTrue(tracker.verify_conversation(Page(URL, body), TREND, 1))

    def test_identity_wrong_revision(self):
        body = "You said:\nIdentificador: " + TREND + ". Revisión: 2."
        self.assertFalse(tracker.verify_conversation(Page(URL, body), TREND, 1))

    def test_identity_only_in_assistant_is_rejected(self):
        body = "You said:\nDime algo.\nChatGPT said:\n" + TREND + " Revisión: 1"
        self.assertFalse(tracker.verify_conversation(Page(URL, body), TREND, 1))

    def test_no_new_target_timeout(self):
        browser = Browser([Page("https://chatgpt.com/", "")], [URL])
        page = browser.contexts[0].pages[0]
        result, diag = tracker.await_conversation(
            browser, page, TREND, 1, seconds=0, baseline_urls=[])
        self.assertIsNone(result)
        self.assertEqual(diag["status"], "not_found")

if __name__ == "__main__":
    unittest.main()
