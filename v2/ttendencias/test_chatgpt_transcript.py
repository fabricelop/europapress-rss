#!/usr/bin/env python3
"""Pruebas aisladas: sin Chrome, sin red, sin GitHub y sin V1."""
import unittest
from unittest.mock import patch

try:
    from .chatgpt_transcript import extract_reply, read_status, read_dom_pair, capture_existing_page
except ImportError:
    from chatgpt_transcript import extract_reply, read_status, read_dom_pair, capture_existing_page

TREND = "trv2-dd5de9a892ab6b7007ef26b6"
BODY = (
    "ChatGPT\nNew chat\nExplicación tendencia #SVFinal\n"
    "You said:\nTTActualidad V2. Identificador " + TREND + ", revision 1.\n"
    "Worked for 15s\nChatGPT said:\nVERIFICADO\n"
    "Explicación editorial\n#SVFinal es tendencia por una final televisiva.\n"
    + ("Texto de la respuesta, fuentes y contexto periodístico. " * 3)
    + "\nNo se ha publicado contenido ni modificado GitHub.\n"
    "ChatGPT can make mistakes. Check important info.\nLatest response"
)
class TestTranscript(unittest.TestCase):
    def test_hidden_stop_button_does_not_hold_a_complete_answer_forever(self):
        clock = [0.0]

        class Locator:
            def __init__(self, kind, visible):
                self.kind, self.visible = kind, visible
            def count(self): return 1 if self.kind == "stop" else 0
            def nth(self, index):
                assert index == 0
                return self
            def is_visible(self): return self.visible
            def inner_text(self, timeout=8000): return BODY

        class Page:
            url = "https://chatgpt.com/c/verified"
            def __init__(self, stop_visible): self.stop_visible = stop_visible
            def locator(self, selector):
                return Locator("stop", self.stop_visible) if "stop-button" in selector else Locator("body", False)

        def advance(seconds): clock[0] += seconds
        with (patch("time.monotonic", side_effect=lambda: clock[0]),
              patch("time.sleep", side_effect=advance)):
            captured = capture_existing_page(Page(False), trend_id=TREND,
                                             revision=1, seconds=12)
        self.assertEqual(captured["status"], "captured")
        clock[0] = 0
        with (patch("time.monotonic", side_effect=lambda: clock[0]),
              patch("time.sleep", side_effect=advance)):
            unfinished = capture_existing_page(Page(True), trend_id=TREND,
                                              revision=1, seconds=12)
        self.assertEqual(unfinished["status"], "timeout")
        self.assertEqual(unfinished["reason"], "visible_transcript_bound_to_prompt_and_footer")

    def test_changing_chatgpt_elapsed_timer_does_not_break_stability(self):
        clock = [0.0]
        calls = [0]
        class Locator:
            def __init__(self, kind): self.kind=kind
            def count(self): return 0
            def inner_text(self, timeout=8000):
                calls[0] += 1
                return BODY.replace("VERIFICADO\n", "Worked for %ds\nVERIFICADO\n" % calls[0])
        class Page:
            url = "https://chatgpt.com/c/verified"
            def locator(self, selector):return Locator("body")
        def advance(seconds):clock[0] += seconds
        with (patch("time.monotonic", side_effect=lambda: clock[0]),
              patch("time.sleep", side_effect=advance)):
            captured = capture_existing_page(Page(), trend_id=TREND,
                                             revision=1, seconds=12)
        self.assertEqual(captured["status"], "captured")
        self.assertNotIn("Worked for", captured["answer"])

    def test_activity_callback_requires_new_assistant_text_not_spinners(self):
        clock=[0.0]
        progress=[]
        class Locator:
            def __init__(self, kind, page): self.kind=kind;self.page=page
            def count(self):return 1 if self.kind=="assistant" else 0
            @property
            def last(self):return self
            def inner_text(self,timeout=8000):
                if self.kind=="body":return "ChatGPT vacío"
                self.page.calls+=1
                return ("Investigando" if self.page.calls==1 else
                        "Investigando con resultados contrastados")
        class Page:
            url="https://chatgpt.com/c/test"
            calls=0
            def locator(self, selector):
                return Locator("body" if selector=="body" else
                               "assistant" if 'assistant' in selector else "other", self)
        def sleep(seconds):clock[0]+=seconds
        with (patch("time.monotonic",side_effect=lambda:clock[0]),
              patch("time.sleep",side_effect=sleep)):
            result=capture_existing_page(Page(),trend_id=TREND,revision=1,
                                         seconds=6,on_activity=progress.append)
        self.assertEqual(result["status"],"timeout")
        self.assertEqual(progress,[len("Investigando"),len("Investigando con resultados contrastados")])

    def test_complete_answer_is_captured_on_same_page_without_url(self):
        class Locator:
            def __init__(self, text): self.text = text
            def inner_text(self, timeout=8000): return self.text
            def count(self): return 0
        class Page:
            url = "https://chatgpt.com/"
            def locator(self, selector):
                return Locator(BODY if selector == "body" else "")
        with (patch("time.monotonic", side_effect=[0, .1, .2, .3, .4, .5]),
              patch("time.sleep")):
            result = capture_existing_page(Page(), trend_id=TREND,
                                           revision=1, seconds=2)
        self.assertEqual(result["status"], "captured")
        self.assertEqual(result["url"], "https://chatgpt.com/")
        self.assertIn("#SVFinal", result["answer"])

    def test_existing_answer(self):
        answer, reason = extract_reply(BODY, trend_id=TREND, revision=1)
        self.assertIn("#SVFinal es tendencia", answer)
        self.assertNotIn("ChatGPT can make mistakes.", answer)
        self.assertEqual(reason, "visible_transcript_bound_to_prompt_and_footer")
    def test_spanish_interface_complete(self):
        body = BODY.replace("You said:", "Tú dijiste:").replace(
            "ChatGPT said:", "ChatGPT dijo:").replace(
            "ChatGPT can make mistakes.", "ChatGPT puede cometer errores.")
        answer, reason = extract_reply(body, trend_id=TREND, revision=1)
        self.assertIn("Explicación editorial", answer)
        self.assertEqual(reason, "visible_transcript_bound_to_prompt_and_footer")

    def test_spanish_interface_rejects_wrong_revision(self):
        body = BODY.replace("You said:", "Tú dijiste:").replace(
            "ChatGPT said:", "ChatGPT dijo:").replace(
            "ChatGPT can make mistakes.", "ChatGPT puede cometer errores.")
        self.assertEqual(extract_reply(body, trend_id=TREND, revision=2)[0], "")

    def test_dom_single_pair_accepts_without_footer(self):
        class Node:
            def __init__(self,text="",markdown=None):
                self.text=text
                self.markdown=markdown
            def count(self): return 1
            @property
            def first(self): return self
            def inner_text(self,timeout=6000):return self.text
            def locator(self,sel):
                return Node(self.markdown) if self.markdown else Missing()
        class Missing:
            def count(self):return 0
        class Page:
            def locator(self,sel):
                if 'user' in sel: return Node("Identificador: " + TREND + ". Revisión: 1.")
                if 'assistant' in sel:
                    return Node("Toolbar Copy", markdown="Investigación contrastada " * 8)
                raise AssertionError(sel)
        answer, reason = read_dom_pair(Page(), trend_id=TREND, revision=1)
        self.assertIn("Investigación", answer)
        self.assertEqual(reason, "dom_single_pair_verified")
        self.assertNotIn("Toolbar",answer)

    def test_wrong_revision(self):
        self.assertEqual(extract_reply(BODY, trend_id=TREND, revision=2)[0], "")
    def test_wrong_id(self):
        self.assertEqual(extract_reply(BODY, trend_id="different", revision=1)[0], "")
    def test_unfinished(self):
        self.assertEqual(extract_reply(BODY.split("ChatGPT can make mistakes.")[0], trend_id=TREND, revision=1)[0], "")
    def test_followup_turn(self):
        extra = BODY.replace("ChatGPT can make mistakes.", "\nYou said:\nOtra orden\nChatGPT can make mistakes.")
        self.assertEqual(extract_reply(extra, trend_id=TREND, revision=1)[0], "")
    def test_visible_loading_failure(self):
        result = read_status("Could not load this ChatGPT conversation",
                             trend_id=TREND, revision=1)
        self.assertEqual(result["status"], "conversation_load_failed")
        self.assertEqual(result["answer"], "")

    def test_status_waits_for_completion(self):
        result = read_status(BODY.split("ChatGPT can make mistakes.")[0],
                             trend_id=TREND, revision=1)
        self.assertEqual(result["status"], "waiting")

    def test_status_captures_matching_transcript(self):
        result = read_status(BODY, trend_id=TREND, revision=1)
        self.assertEqual(result["status"], "captured")

    def test_empty(self):
        self.assertEqual(extract_reply("", trend_id=TREND, revision=1)[0], "")
if __name__ == "__main__":
    unittest.main()
