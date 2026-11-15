import unittest

from v2.ttendencias.re_request_v2 import request_reexplanation


ID = "trv2-1234567890abcdef12345678"
WHEN = "2026-11-15T13:02:00Z"


class ReRequestTest(unittest.TestCase):
    def setUp(self):
        self.history = {"step": "03_movement", "country": "ES",
                        "observed_at": "2026-11-15T14:00:00Z",
                        "topics": {"x": {"trend_id": ID, "active": True, "rank": 1,
                                         "entered_top30_at": WHEN}}}
        self.queue = {"step": "04_editorial_queue", "effects_enabled": False,
                      "source_observed_at": self.history["observed_at"],
                      "items": {ID: {"trend_id": ID, "status": "captured_review", "revision": 1,
                                     "capture": {"revision": 1, "answer": "Texto antiguo", "image": {"status": "saved"}}}},
                      "pending_ids": [], "pending_count": 0}

    def invoke(self, **changes):
        args = {"trend_id": ID, "base_revision": 1, "entered_top30_at": WHEN,
                "requested_at": "2026-11-15T14:10:00Z"}
        args.update(changes)
        return request_reexplanation(self.queue, self.history, **args)

    def test_keeps_previous_capture_but_unbinds_it_from_new_revision(self):
        updated, status = self.invoke()
        self.assertEqual(status, "ENQUEUED")
        row = updated["items"][ID]
        self.assertEqual(row["revision"], 2)
        self.assertEqual(row["status"], "review_pending")
        self.assertNotIn("capture", row)
        self.assertEqual(row["previous_capture"]["image"]["status"], "saved")
        self.assertEqual(updated["pending_ids"], [ID])
        self.assertIn("capture", self.queue["items"][ID])

    def test_reject_changed_episode(self):
        with self.assertRaises(ValueError):
            self.invoke(entered_top30_at="2026-11-14T01:00:00Z")

    def test_idempotent(self):
        updated, _ = self.invoke()
        again, status = request_reexplanation(updated, self.history, trend_id=ID,
            base_revision=1, entered_top30_at=WHEN, requested_at="later")
        self.assertEqual(status, "ALREADY_APPLIED")
        self.assertEqual(again["items"][ID]["revision"], 2)


if __name__ == "__main__":
    unittest.main()
