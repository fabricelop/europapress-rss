import copy
import unittest
from reelaboration_v2 import request, apply

TID = "trv2-e94b2984c087ac403753b8c1"
WHEN = "2026-11-14T06:00:00+00:00"


def queue(status="captured_review", extra=None):
    row = {"trend_id": TID, "name": "Jordi Wild", "revision": 1,
           "status": status, "attempts": 1, "requested_at": WHEN,
           "updated_at": WHEN, "episode_token": "one",
           "capture": {"revision": 1, "answer": "Una ficha original",
                       "sha256": "a" * 64, "chat_url": "https://chatgpt.com/c/123"}}
    row.update(extra or {})
    return {"schema_version": 1, "step": "04_editorial_queue",
            "effects_enabled": False, "country": "ES",
            "source_observed_at": WHEN, "items": {TID: row},
            "pending_ids": [TID], "pending_count": 1}


class ReelaborationTests(unittest.TestCase):
    def test_each_status_can_request(self):
        for status in ("pending", "review_pending", "in_progress",
                       "capture_recovery", "captured_review", "ready",
                       "published", "dismissed", "cancelled"):
            with self.subTest(status=status):
                before = queue(status)
                out, action = request(before, trend_id=TID,
                    expected_revision=1, issue_number=427,
                    requested_by="fabricelop", now=WHEN)
                self.assertEqual(action, "recorded")
                self.assertEqual(out["items"][TID]["status"], status)
                self.assertNotIn("reelaboration_requested", before["items"][TID])
                self.assertIn("reelaboration_requested", out["items"][TID])

    def test_busy_defers_without_loss(self):
        before = queue("in_progress", {"lease": {"token": "live"},
                                       "send_intent": {"token": "live"}})
        requested, _ = request(before, trend_id=TID,
            expected_revision=1, issue_number=427, requested_by="fabricelop", now=WHEN)
        deferred, state = apply(requested, trend_id=TID, now=WHEN)
        self.assertEqual(state, "deferred_active_chat")
        self.assertEqual(deferred, requested)
        self.assertEqual(deferred["items"][TID]["revision"], 1)

    def test_new_revision_preserves_original(self):
        q = queue("captured_review")
        claimed, _ = request(q, trend_id=TID, expected_revision=1,
                             issue_number=427, requested_by="fabricelop", now=WHEN)
        new, action = apply(claimed, trend_id=TID, now=WHEN)
        self.assertEqual(action, "applied")
        row = new["items"][TID]
        self.assertEqual(row["revision"], 2)
        self.assertEqual(row["status"], "review_pending")
        self.assertEqual(row["attempts"], 0)
        self.assertNotIn("capture", row)
        self.assertEqual(row["revision_history"][0]["capture"]["answer"], "Una ficha original")
        self.assertEqual(row["revision_history"][0]["status"], "captured_review")
        self.assertEqual(new["pending_ids"], [TID])
        self.assertEqual(q["items"][TID]["revision"], 1)

    def test_request_is_idempotent(self):
        q = queue()
        first, _ = request(q, trend_id=TID, expected_revision=1,
                           issue_number=427, requested_by="fabricelop", now=WHEN)
        second, status = request(first, trend_id=TID, expected_revision=1,
                                 issue_number=428, requested_by="fabricelop", now=WHEN)
        self.assertEqual(status, "already_requested")
        self.assertEqual(second, first)
        with self.assertRaisesRegex(ValueError, "revision"):
            request(first, trend_id=TID, expected_revision=2,
                    issue_number=429, requested_by="fabricelop")

    def test_stale_revision_denied(self):
        with self.assertRaises(ValueError):
            request(queue(), trend_id=TID, expected_revision=2,
                    issue_number=427, requested_by="fabricelop")

    def test_non_owner_denied(self):
        with self.assertRaises(ValueError):
            request(queue(), trend_id=TID, expected_revision=1,
                    issue_number=427, requested_by="public")

    def test_captured_pending_not_ready(self):
        q = queue("published", {"text": "Publicado en X antes",
                                "image": {"url": "https://example.org/image.png",
                                          "status": "ready"}})
        req, _ = request(q, trend_id=TID, expected_revision=1,
                         issue_number=427, requested_by="fabricelop", now=WHEN)
        new, _ = apply(req, trend_id=TID, now=WHEN)
        self.assertEqual(new["items"][TID]["status"], "review_pending")
        self.assertNotIn("image", new["items"][TID])
        self.assertEqual(new["items"][TID]["revision_history"][0]["image"]["status"], "ready")
        self.assertEqual(new["items"][TID]["revision_history"][0]["text"], "Publicado en X antes")


if __name__ == "__main__":
    unittest.main()
