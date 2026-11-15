#!/usr/bin/env python3
"""RE polling planner: no network, no private credentials, no publication."""
import unittest

from sync_private_re_v2 import plan_requested_reviews

ID = "trv2-" + "a" * 24


class PrivateRePlannerTest(unittest.TestCase):
    def setUp(self):
        self.history = {"step": "03_movement", "country": "ES", "observed_at": "2026-11-15T18:00:00Z",
                        "topics": {"old": {"trend_id": ID, "active": False, "rank": None}}}
        self.queue = {"step": "04_editorial_queue", "effects_enabled": False,
                      "source_observed_at": self.history["observed_at"],
                      "items": {ID: {"trend_id": ID, "status": "captured_review", "revision": 1,
                                     "attempts": 2, "capture": {"answer": "Vieja explicación"}}}}

    def test_public_re_applies_to_historical_topic_once(self):
        row = {"trend_id": ID, "base_revision": 1}
        updated, changed, ignored = plan_requested_reviews(self.queue, self.history, [row])
        self.assertEqual(changed, [ID])
        self.assertEqual(ignored, 0)
        self.assertEqual(updated["items"][ID]["revision"], 2)
        self.assertEqual(updated["items"][ID]["attempts"], 0)
        self.assertNotIn("capture", updated["items"][ID])
        again, changed, ignored = plan_requested_reviews(updated, self.history, [row])
        self.assertEqual(changed, [])
        self.assertEqual(ignored, 0)
        self.assertEqual(again, updated)

    def test_invalid_and_unrelated_requests_never_mutate_queue(self):
        updated, changed, ignored = plan_requested_reviews(self.queue, self.history,
            [{"trend_id": "trv2-" + "b" * 24, "base_revision": 1},
             {"trend_id": ID, "base_revision": True}, {}, None])
        self.assertEqual(changed, [])
        self.assertEqual(ignored, 3)
        self.assertEqual(updated, self.queue)

    def test_queue_revision_and_capture_are_not_overwritten_by_stale_re(self):
        self.queue["items"][ID].update(revision=2,status="in_progress",capture=None)
        updated, changed, ignored = plan_requested_reviews(self.queue, self.history,
            [{"trend_id": ID, "base_revision": 1}])
        self.assertEqual(changed, [])
        self.assertEqual(ignored, 0)
        self.assertEqual(updated, self.queue)


if __name__ == "__main__":
    unittest.main()
