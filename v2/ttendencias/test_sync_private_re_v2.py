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


    def test_incident_hints_do_not_interrupt_active_or_expired_editorial_run(self):
        original = self.queue["items"][ID]
        original.update(status="in_progress", lease={"expires_at": "2026-11-15T17:00:00Z"},
                        send_intent={"token": "recorded", "at": "2026-11-15T16:40:00Z"})
        request = {"trend_id": ID, "base_revision": 1, "purpose": "incident_hints",
                   "hints": "Contrastar en X la conversación reciente sobre esta noticia."}
        updated, applied, ignored = plan_requested_reviews(self.queue, self.history, [request])
        self.assertEqual((applied, ignored), ([ID], 0))
        self.assertEqual(updated["items"][ID]["revision"], 1)
        self.assertEqual(updated["items"][ID]["status"], "in_progress")
        self.assertEqual(updated["items"][ID]["send_intent"], original["send_intent"])
        self.assertEqual(updated["items"][ID]["lease"], original["lease"])
        self.assertNotIn("incident_review_hints_pending", original)
        again, applied, ignored = plan_requested_reviews(updated, self.history, [request])
        self.assertEqual((applied, ignored), ([], 0))
        self.assertEqual(again, updated)

    def test_terminal_cancelled_incident_is_enqueued_once_with_hints(self):
        self.queue["items"][ID]["status"] = "cancelled"
        req = {"trend_id": ID, "base_revision": 1, "purpose": "incident_hints",
               "hints": "Revisar el hashtag de ayer y contrastar los datos con prensa."}
        updated, applied, ignored = plan_requested_reviews(self.queue, self.history, [req])
        self.assertEqual((applied, ignored), ([ID], 0))
        self.assertEqual(updated["items"][ID]["status"], "review_pending")
        self.assertEqual(updated["items"][ID]["review_mode"], "x")
        self.assertEqual(updated["items"][ID]["review_hints"], req["hints"])
        self.assertNotIn("capture", updated["items"][ID])
        again, changed, ignored = plan_requested_reviews(updated, self.history, [req])
        self.assertEqual(changed, [])
        self.assertEqual(ignored, 0)
        self.assertEqual(again, updated)

    def test_manual_retry_marks_active_incident_without_replaying_send(self):
        original = self.queue["items"][ID]
        original.update(status="in_progress", incident_retries=2,
                        lease={"expires_at":"2026-11-15T18:10:00Z"},
                        send_intent={"at":"2026-11-15T17:55:00Z"})
        req = {"purpose":"incident_manual_retry", "trend_id":ID, "base_revision":1,
               "instructions":"Verifica las fuentes antes de redactar otra vez."}
        updated, applied, ignored = plan_requested_reviews(self.queue,self.history,[req])
        self.assertEqual((applied,ignored),([ID],0))
        item=updated["items"][ID]
        self.assertEqual((item["revision"],item["status"]),(1,"in_progress"))
        self.assertEqual(item["send_intent"],original["send_intent"])
        self.assertEqual(item["lease"],original["lease"])
        self.assertIn("manual_retry_requested_at",item)
        again,applied,ignored=plan_requested_reviews(updated,self.history,[req])
        self.assertEqual((applied,ignored),([],0))
        self.assertEqual(again,updated)

    def test_manual_retry_of_terminal_incident_starts_fresh_revision(self):
        self.queue["items"][ID].update(status="cancelled", incident_retries=2)
        req={"purpose":"incident_manual_retry", "trend_id":ID, "base_revision":1,
             "instructions":""}
        updated,applied,ignored=plan_requested_reviews(self.queue,self.history,[req])
        self.assertEqual((applied,ignored),([ID],0))
        self.assertEqual(updated["items"][ID]["revision"],2)
        self.assertEqual(updated["items"][ID]["status"],"review_pending")
        self.assertEqual(updated["items"][ID]["incident_retries"],0)


if __name__ == "__main__":
    unittest.main()
