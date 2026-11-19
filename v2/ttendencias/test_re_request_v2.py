import unittest

from re_request_v2 import request_reexplanation
from editorial_capture_state import stage_capture


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
        self.queue["items"][ID]["image_progress"] = {
            "status": "in_progress", "revision": 1, "command_id": "old-command"}
        updated, status = self.invoke()
        self.assertEqual(status, "ENQUEUED")
        row = updated["items"][ID]
        self.assertEqual(row["revision"], 2)
        self.assertEqual(row["status"], "review_pending")
        self.assertEqual(row["reason"], "user_reset")
        self.assertEqual(row["previous_attempts"][-1]["revision"], 1)
        self.assertEqual(row["previous_attempts"][-1]["status"], "captured_review")
        self.assertEqual(row["attempts"], 0)
        self.assertNotIn("capture", row)
        self.assertNotIn("previous_capture", row)
        self.assertNotIn("previous_explanation", row)
        self.assertNotIn("previous_revision", row)
        self.assertNotIn("image_progress", row)
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

    def test_pending_re_x_creates_fresh_prioritized_revision_with_hints(self):
        self.queue["items"][ID].update(status="pending", attempts=2)
        self.queue["items"][ID].pop("capture")
        hints = "Revisar comentarios recientes sobre el término y contrastarlos."
        result, action = self.invoke(mode="x", hints=hints)
        row = result["items"][ID]
        self.assertEqual(action, "ENQUEUED")
        self.assertEqual((row["revision"], row["status"]), (2, "review_pending"))
        self.assertEqual(row["review_mode"], "x")
        self.assertEqual(row["review_hints"], hints)
        self.assertEqual(row["reason"], "user_reexplanation")
        self.assertEqual(row["attempts"], 0)
        self.assertNotIn("send_intent", row)

    def test_active_re_x_stages_without_mutating_lease_or_existing_prompt(self):
        old = self.queue["items"][ID]
        old.update(status="in_progress", lease={"token": "LIVE", "expires_at": WHEN},
                   send_intent={"token": "LIVE"})
        old.pop("capture")
        hints = "Buscar el vídeo original difundido hoy en X y contrastar fechas."
        result, action = self.invoke(mode="x", hints=hints)
        row = result["items"][ID]
        self.assertEqual(action, "STAGED")
        self.assertEqual((row["revision"], row["status"]), (1, "in_progress"))
        self.assertEqual(row["lease"]["token"], "LIVE")
        self.assertEqual(row["send_intent"]["token"], "LIVE")
        self.assertEqual(row["incident_review_hints_pending"], hints)
        self.assertNotIn("review_hints", row)
        again, action2 = request_reexplanation(result, self.history,
            trend_id=ID, base_revision=1, entered_top30_at=WHEN,
            requested_at="later", mode="x", hints=hints)
        self.assertEqual(action2, "ALREADY_STAGED")
        self.assertEqual(again, result)
        self.assertNotIn("deferred_re_request", old)
        result["items"][ID]["status"] = "captured_review"
        result["items"][ID]["capture"] = {"answer": "Original completo"}
        next_rev, action3 = request_reexplanation(result, self.history,
            trend_id=ID, base_revision=1, entered_top30_at=WHEN,
            requested_at="later", mode="x", hints=hints)
        self.assertEqual(action3, "ENQUEUED")
        self.assertEqual(next_rev["items"][ID]["revision"], 2)
        self.assertEqual(next_rev["items"][ID]["review_hints"], hints)
        self.assertNotIn("deferred_re_request", next_rev["items"][ID])

    def test_active_re_resets_immediately_and_fences_previous_chat(self):
        old = self.queue["items"][ID]
        old.update(status="in_progress", lease={"token": "LIVE", "worker_id": "worker"},
                   send_intent={"token": "LIVE", "at": WHEN})
        old.pop("capture")
        result, action = self.invoke()
        row = result["items"][ID]
        self.assertEqual(action, "ENQUEUED")
        self.assertEqual((row["revision"], row["status"], row["reason"]),
                         (2, "review_pending", "user_reset"))
        self.assertNotIn("lease", row)
        self.assertNotIn("send_intent", row)
        self.assertEqual(row["previous_attempts"][-1]["sent_at"], WHEN)
        self.assertEqual(old["lease"]["token"], "LIVE")
        self.assertEqual(old["status"], "in_progress")
        with self.assertRaisesRegex(ValueError, "obsoletos"):
            stage_capture(result, trend_id=ID, revision=1,
                          answer="Una captura del chat antiguo " * 5,
                          chat_url="https://chatgpt.com/c/old-chat",
                          validated_capture=True, lease_token="LIVE")

    def test_capture_recovery_can_be_reset_without_waiting(self):
        old = self.queue["items"][ID]
        old.update(status="capture_recovery", send_intent={"token": "sent"})
        old.pop("capture")
        result, action = self.invoke()
        self.assertEqual(action, "ENQUEUED")
        self.assertEqual(result["items"][ID]["revision"], 2)
        self.assertNotIn("send_intent", result["items"][ID])

    def test_cancelled_incident_can_be_reset(self):
        self.queue["items"][ID].update(status="cancelled", incident_retries=2)
        self.queue["items"][ID].pop("capture")
        result, action = self.invoke()
        self.assertEqual(action, "ENQUEUED")
        self.assertEqual(result["items"][ID]["incident_retries"], 0)

    def test_pending_with_send_evidence_can_be_explicitly_reset(self):
        self.queue["items"][ID].update(status="pending", send_intent={"token": "maybe-sent"})
        self.queue["items"][ID].pop("capture")
        result, action = self.invoke()
        self.assertEqual(action, "ENQUEUED")
        self.assertEqual(result["items"][ID]["revision"], 2)
        self.assertNotIn("send_intent", result["items"][ID])
        with self.assertRaisesRegex(ValueError, "evidencia"):
            self.invoke(mode="x", hints="Investiga los mensajes recientes en X con fuentes.")

    def test_unknown_historical_identity_rejected(self):
        self.history["topics"].clear()
        with self.assertRaisesRegex(ValueError, "historial"):
            self.invoke()


if __name__ == "__main__":
    unittest.main()
