#!/usr/bin/env python3
"""Pruebas aisladas: sin Chrome, sin red, sin GitHub y sin V1."""
import unittest
from chatgpt_transcript import extract_reply, read_status

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
