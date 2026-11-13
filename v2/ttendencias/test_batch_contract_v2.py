#!/usr/bin/env python3
"""Tests V2 sin navegador ni red para selección y persistencia secuencial."""
import hashlib
import unittest
from batch_contract_v2 import eligible_items, verify_persisted

def queue():
    return {"step": "04_editorial_queue", "effects_enabled": False, "items": {
        "a": {"trend_id": "a", "name": "A", "revision": 1, "status": "pending",
              "requested_at": "2026-11-13T09:00:00Z"},
        "b": {"trend_id": "b", "name": "B", "revision": 1, "status": "pending",
              "requested_at": "2026-11-13T08:00:00Z", "send_intent": {"token": "sent"}},
        "c": {"trend_id": "c", "name": "C", "revision": 1, "status": "captured_review"},
        "d": {"trend_id": "d", "name": "D", "revision": 1, "status": "capture_recovery"},
        "e": {"trend_id": "e", "name": "E", "revision": 1, "status": "review_pending",
              "requested_at": "2026-11-13T09:01:00Z"},
        "f": {"trend_id": "f", "name": "F", "revision": 1, "status": "pending",
              "requested_at": "2026-11-13T07:00:00Z", "attempts": 3},
        "g": {"trend_id": "g", "name": "G", "revision": 1, "status": "pending",
              "requested_at": "2026-11-13T07:00:00Z", "lease": {"token": "active"}},
    }}

def persisted():
    text = "Texto de respuesta editorial validada para captura " * 4
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    journal = {"trend_id": "a", "revision": 1, "message_sent": True,
               "reply_captured": True, "cleanup_verified": True,
               "persisted": True, "answer": text, "chat_url": "https://chatgpt.com/c/abc",
               "remaining_v2_pids": []}
    q = queue()
    q["items"]["a"].update(status="captured_review", capture={
        "sha256": digest, "answer": text,
        "chat_url": journal["chat_url"], "verified_complete": True,
        "editorial_validated": False})
    return q, journal

class TestBatchContract(unittest.TestCase):
    def test_only_unsent_and_without_lease(self):
        self.assertEqual([x["trend_id"] for x in eligible_items(queue(), 3)], ["a", "e"])
    def test_dry_selection_not_mutating(self):
        q = queue()
        eligible_items(q, 2)
        self.assertEqual(q["items"]["a"]["status"], "pending")
    def test_effects_enabled_refused(self):
        q = queue()
        q["effects_enabled"] = True
        with self.assertRaises(ValueError): eligible_items(q, 2)
    def test_limits_enforced(self):
        for n in [0, 4, -1]:
            with self.assertRaises(ValueError): eligible_items(queue(), n)
    def test_verified_stage(self):
        q, journal = persisted()
        self.assertEqual(verify_persisted(q, journal),
                         q["items"]["a"]["capture"]["sha256"])
    def test_wrong_hash_refused(self):
        q, journal = persisted()
        q["items"]["a"]["capture"]["sha256"] = "broken"
        with self.assertRaises(ValueError): verify_persisted(q, journal)
    def test_wrong_revision_refused(self):
        q, journal = persisted()
        q["items"]["a"]["revision"] = 2
        with self.assertRaises(ValueError): verify_persisted(q, journal)
    def test_chrome_not_closed_refused(self):
        q, journal = persisted()
        journal["remaining_v2_pids"] = [1234]
        with self.assertRaises(ValueError): verify_persisted(q, journal)
    def test_editorial_ready_refused(self):
        q, journal = persisted()
        q["items"]["a"]["status"] = "ready"
        with self.assertRaises(ValueError): verify_persisted(q, journal)
    def test_no_second_without_verified_capture(self):
        q, journal = persisted()
        journal["persisted"] = False
        with self.assertRaises(ValueError): verify_persisted(q, journal)

if __name__ == "__main__":
    unittest.main()
