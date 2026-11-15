import unittest

from re_request_v2 import request_reexplanation


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

    def test_restarts_entire_editorial_without_previous_text_or_image(self):
        self.queue["items"][ID]["attempts"] = 3
        updated, status = self.invoke()
        self.assertEqual(status, "ENQUEUED")
        row = updated["items"][ID]
        self.assertEqual(row["revision"], 2)
        self.assertEqual(row["status"], "review_pending")
        self.assertEqual(row["attempts"], 0)
        self.assertNotIn("capture", row)
        self.assertNotIn("previous_capture", row)
        self.assertNotIn("previous_explanation", row)
        self.assertNotIn("previous_revision", row)
        self.assertEqual(updated["pending_ids"], [ID])
        self.assertIn("capture", self.queue["items"][ID])

    def test_accept_independent_cloudflare_and_github_entry_clocks(self):
        updated, status = self.invoke(entered_top30_at="2026-11-14T01:00:00Z")
        self.assertEqual(status, "ENQUEUED")
        self.assertEqual(updated["items"][ID]["revision"], 2)

    def test_idempotent(self):
        updated, _ = self.invoke()
        again, status = request_reexplanation(updated, self.history, trend_id=ID,
            base_revision=1, entered_top30_at=WHEN, requested_at="later")
        self.assertEqual(status, "ALREADY_APPLIED")
        self.assertEqual(again["items"][ID]["revision"], 2)

    def test_reexplain_after_leaving_top30(self):
        self.history["topics"]["x"].update(active=False, rank=None)
        updated, action = self.invoke()
        self.assertEqual(action, "ENQUEUED")
        self.assertEqual(updated["items"][ID]["revision"], 2)
        self.assertEqual(updated["items"][ID]["status"], "review_pending")

    def test_re_x_persists_hints_and_search_mode(self):
        hints = "Buscar hilo y vídeo de hoy, contrastar origen del hashtag."
        updated, action = self.invoke(mode="x", hints=hints)
        self.assertEqual(action, "ENQUEUED")
        self.assertEqual(updated["items"][ID]["review_mode"], "x")
        self.assertEqual(updated["items"][ID]["review_hints"], hints)
        self.assertNotIn("review_hints", self.queue["items"][ID])

    def test_re_x_rejects_empty_hints(self):
        with self.assertRaisesRegex(ValueError, "pistas"):
            self.invoke(mode="x", hints="corto")

    def test_unknown_historical_identity_rejected(self):
        self.history["topics"].clear()
        with self.assertRaisesRegex(ValueError, "historial"):
            self.invoke()


if __name__ == "__main__":
    unittest.main()
