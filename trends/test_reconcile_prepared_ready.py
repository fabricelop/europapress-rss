"""Offline tests for legacy READY -> explained repair without Telegram/images."""
import copy
import unittest
from reconcile_prepared_ready import reconcile_prepared_ready


class ReadyRepairTests(unittest.TestCase):
    def setUp(self):
        self.requests = {"requests": [
            {"id": "aaaa1111bbbb", "name": "Paracetamol", "revision": 0,
             "status": "ready", "requested_at": "2026-10-27T19:51:00Z"},
            {"id": "cccc2222dddd", "name": "Lamine", "revision": 0,
             "status": "ready", "requested_at": "2026-10-28T01:51:00Z"}
        ]}
        self.prepared = {"items": [
            {"id": "aaaa1111bbbb", "trend_name": "Paracetamol", "revision": 0,
             "generated_at": "2026-10-27T20:07:02Z", "rank": 9,
             "explanation": "TT#9 Paracetamol es tendencia. #Paracetamol\n🌶️ Un remate.",
             "closer_text": "🌶️ Un remate.", "group_leader_id": "aaaa1111bbbb"},
            {"id": "cccc2222dddd", "trend_name": "Lamine", "revision": 0,
             "generated_at": "2026-10-28T02:00:30Z", "rank": 7,
             "explanation": "TT#7 Lamine es tendencia. #Lamine\n🌶️ Otro remate.",
             "closer_text": "🌶️ Otro remate.", "group_leader_id": "cccc2222dddd"},
        ]}
        self.explained = {"items": []}
        self.now = "2026-10-28T22:10:00+01:00"

    def run_repair(self):
        return reconcile_prepared_ready(self.requests, self.prepared,
                                        self.explained, self.now)

    def test_both_ready_promoted_without_images(self):
        self.assertEqual(self.run_repair(), 2)
        self.assertEqual({x["status"] for x in self.requests["requests"]}, {"explained"})
        self.assertEqual({x["id"] for x in self.explained["items"]},
                         {"aaaa1111bbbb", "cccc2222dddd"})
        self.assertTrue(all(x["image_pending"] is False for x in self.explained["items"]))

    def test_idempotent_second_pass(self):
        self.assertEqual(self.run_repair(), 2)
        self.assertEqual(self.run_repair(), 0)
        self.assertEqual(len(self.explained["items"]), 2)

    def test_refuse_prior_deleted_revision(self):
        self.explained["items"] = [
            {"id": "aaaa1111bbbb", "revision": 0, "status": "deleted"}
        ]
        self.assertEqual(self.run_repair(), 1)
        self.assertEqual(self.requests["requests"][0]["status"], "ready")

    def test_refuse_newer_revision(self):
        self.requests["requests"].append({
            "id": "aaaa1111bbbb", "revision": 1, "status": "preparing",
            "requested_at": self.now,
        })
        self.assertEqual(self.run_repair(), 1)

    def test_old_text_does_not_close_new_request(self):
        self.requests["requests"][1]["requested_at"] = "2026-10-28T20:00:00Z"
        self.assertEqual(self.run_repair(), 1)
        self.assertEqual(self.requests["requests"][1]["status"], "ready")

    def test_invalid_text_is_not_promoted(self):
        self.prepared["items"][0]["explanation"] = "no prefix"
        self.prepared["items"][1]["closer_text"] = "🌶️ Not present"
        self.assertEqual(self.run_repair(), 0)

    def test_never_overwrite_existing_explanation(self):
        self.explained["items"]=[{
            "id": "aaaa1111bbbb", "revision": 0, "status": "explained",
            "explanation": "An earlier verified text",
        }]
        self.assertEqual(self.run_repair(), 1)
        self.assertEqual(self.explained["items"][0]["explanation"], "An earlier verified text")


if __name__ == "__main__":
    unittest.main()
