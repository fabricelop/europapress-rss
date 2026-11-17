#!/usr/bin/env python3
"""Regression tests for image retry state; no browser or network needed."""
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

    def test_confirmed_unsent_old_attempt(self):
        row = {"attempt": 1, "status": "failed",
               "error": "V2_IMAGE_PROMPT_NOT_SUBMITTED",
               "submission_observation": {"composer_inspected": True,
                  "composer_contains_command": True,
                  "user_turn_contains_command": False}}
        self.assertEqual(retry_status([row])["state"], "retry_pending")
        self.assertEqual(retry_status([dict(row, attempt=i) for i in (1,2,3)])["state"],
                         "exhausted")

    def test_ambiguous_is_not_retryable(self):
        row = {"attempt": 1, "status": "failed", "error": "V2_IMAGE_NOT_READY"}
        self.assertEqual(retry_status([row])["state"], "unverified")

    def test_in_flight_is_not_exhausted(self):
        rows = [{"attempt": 1, "status": "failed"},
                {"attempt": 2, "status": "sent_waiting_for_image"}]
        self.assertEqual(retry_status(rows)["state"], "unverified")

    def test_saved(self):
        self.assertEqual(retry_status([{"attempt": 1, "status": "saved"}])["state"], "saved")


if __name__ == "__main__":
    unittest.main()
