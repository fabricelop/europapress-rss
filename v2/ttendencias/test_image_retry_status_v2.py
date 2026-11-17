#!/usr/bin/env python3
"""Regression tests for bounded fresh-chat retries and latest-image replacement."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from image_retry_status_v2 import retry_status


class ImageRetryStatusTests(unittest.TestCase):
    def test_fresh(self):
        self.assertEqual(retry_status([])["state"], "pending")

    def test_pre_send_does_not_spend_send_budget(self):
        rows = [{"attempt": i, "status": "pre_send_failed"} for i in (1, 2)]
        result = retry_status(rows)
        self.assertEqual(result["state"], "retry_pending")
        self.assertEqual(result["send_attempts"], 0)

    def test_pre_send_is_bounded(self):
        rows = [{"attempt": i, "status": "pre_send_failed"} for i in (1, 2, 3)]
        self.assertEqual(retry_status(rows)["state"], "exhausted")

    def test_confirmed_unsent_can_retry_in_a_new_chat(self):
        row = {"attempt": 1, "status": "failed",
               "error": "V2_IMAGE_PROMPT_NOT_SUBMITTED",
               "submission_observation": {"composer_inspected": True,
                  "composer_contains_command": True,
                  "user_turn_contains_command": False}}
        result = retry_status([row])
        self.assertEqual(result["state"], "retry_pending")
        self.assertEqual(result["send_attempts"], 1)

    def test_ambiguous_send_can_retry_in_a_new_chat(self):
        row = {"attempt": 1, "status": "failed", "error": "V2_IMAGE_NOT_READY"}
        self.assertEqual(retry_status([row])["state"], "retry_pending")

    def test_in_flight_attempt_is_not_exhausted(self):
        rows = [{"attempt": 1, "status": "failed"},
                {"attempt": 2, "status": "sent_waiting_for_image"}]
        result = retry_status(rows)
        self.assertEqual(result["state"], "retry_pending")
        self.assertEqual(result["send_attempts"], 2)

    def test_failed_known_states_retry_but_unknown_state_blocks(self):
        for status in ("failed", "send_unverified", "starting",
                       "send_intent_recorded", "sent_waiting_for_image"):
            with self.subTest(status=status):
                self.assertEqual(retry_status([{"attempt": 1, "status": status}])["state"],
                                 "retry_pending")
        self.assertEqual(retry_status([{"attempt": 1, "status": "unexpected"}])["state"],
                         "blocked")

    def test_older_send_then_pre_send_failure_can_retry(self):
        rows = [{"attempt": 1, "status": "send_intent_recorded"},
                {"attempt": 2, "status": "pre_send_failed"}]
        result = retry_status(rows)
        self.assertEqual(result["state"], "retry_pending")
        self.assertEqual(result["send_attempts"], 1)

    def test_three_send_attempts_are_exhausted(self):
        rows = [{"attempt": i, "status": "failed"} for i in (1, 2, 3)]
        self.assertEqual(retry_status(rows)["state"], "exhausted")
        self.assertEqual(retry_status(rows)["send_attempts"], 3)

    def test_saved(self):
        self.assertEqual(retry_status([{"attempt": 1, "status": "saved"}])["state"], "saved")

    def test_a_saved_attempt_remains_final_for_that_revision(self):
        rows = [{"attempt": 1, "status": "saved"},
                {"attempt": 2, "status": "failed"}]
        self.assertEqual(retry_status(rows)["state"], "saved")


if __name__ == "__main__":
    unittest.main()
