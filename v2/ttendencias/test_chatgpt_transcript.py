#!/usr/bin/env python3
"""Pruebas aisladas: sin Chrome, sin red, sin GitHub y sin V1."""
import unittest

try:
    from .chatgpt_transcript import extract_reply, read_status, read_dom_pair
except ImportError:
    from chatgpt_transcript import extract_reply, read_status, read_dom_pair

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
