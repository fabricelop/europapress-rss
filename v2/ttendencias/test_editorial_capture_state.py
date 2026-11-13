#!/usr/bin/env python3
"""Unit tests paso 5B; no network, no ChatGPT, no V1."""
import unittest
from v2.ttendencias.editorial_capture_state import stage_capture, mark_ready

ID = "trv2-dd5de9a892ab6b7007ef26b6"
URL = "https://chatgpt.com/c/6af6bf87-b004-83eb-acae-47268afcef15"
ANS = "Explicación editorial de #SVFinal, con datos y referencias por verificar. " * 3
def queue():
    return {"step": "04_editorial_queue", "country": "ES", "effects_enabled": False,
            "items": {ID: {"trend_id": ID, "name": "#SVFinal", "revision": 1,
                           "status": "pending", "requested_at": "2026-11-13T00:00:00+00:00"}},
            "pending_count": 1, "pending_ids": [ID]}

class TestCapture(unittest.TestCase):
    def stage(self):
        return stage_capture(queue(), trend_id=ID, revision=1, answer=ANS,
                             chat_url=URL, validated_capture=True)
    def test_stage(self):
        q, result = self.stage()
        self.assertEqual(result, "staged_pending_editorial_review")
        self.assertEqual(q["items"][ID]["status"], "captured_review")
        self.assertFalse(q["items"][ID]["capture"]["editorial_validated"])
        self.assertEqual(q["pending_count"], 1)
        self.assertEqual(queue()["items"][ID]["status"], "pending")
    def test_idempotence(self):
        q, _ = self.stage()
        q2, result = stage_capture(q, trend_id=ID, revision=1, answer=ANS,
                                   chat_url=URL, validated_capture=True)
        self.assertEqual(result, "already_staged")
        self.assertEqual(q, q2)
    def test_changed_answer_conflict(self):
        q, _ = self.stage()
        with self.assertRaises(ValueError):
            stage_capture(q, trend_id=ID, revision=1, answer=ANS+"different",
                          chat_url=URL, validated_capture=True)
    def test_revision_rejected(self):
        with self.assertRaises(ValueError):
            stage_capture(queue(), trend_id=ID, revision=2, answer=ANS,
                          chat_url=URL, validated_capture=True)
    def test_incomplete_rejected(self):
        with self.assertRaises(ValueError):
            stage_capture(queue(), trend_id=ID, revision=1, answer=ANS,
                          chat_url=URL, validated_capture=False)
    def test_ready_requires_verified_sources(self):
        q, _ = self.stage()
        sha = q["items"][ID]["capture"]["sha256"]
        with self.assertRaises(ValueError):
            mark_ready(q, trend_id=ID, revision=1, expected_sha256=sha,
                       approved_text=ANS, source_urls=[], verified_by="review")
        self.assertEqual(q["items"][ID]["status"], "captured_review")
    def test_ready_after_approval(self):
        q, _ = self.stage()
        sha = q["items"][ID]["capture"]["sha256"]
        result = mark_ready(q, trend_id=ID, revision=1, expected_sha256=sha,
                            approved_text=ANS, source_urls=["https://example.org/source"],
                            verified_by="editorial-check")
        self.assertEqual(result["items"][ID]["status"], "ready")
        self.assertNotIn("answer", result["items"][ID]["capture"])
        self.assertEqual(result["pending_count"], 0)
    def test_closed_item_rejected(self):
        q = queue()
        q["items"][ID]["status"] = "ready"
        with self.assertRaises(ValueError):
            stage_capture(q, trend_id=ID, revision=1, answer=ANS,
                          chat_url=URL, validated_capture=True)

if __name__ == "__main__":
    unittest.main()
