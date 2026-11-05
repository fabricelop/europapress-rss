"""Regression for Top30 returns after an episode has already been treated."""
import importlib.util
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "trends/trend_episode_policy.py"
spec = importlib.util.spec_from_file_location("trend_episode_policy", SOURCE)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class TrendEpisodePolicyTests(unittest.TestCase):
    def test_oscar_puente_resignation_does_not_reenter_after_publish(self):
        old = {
            "id": "oscar-dismissal", "name": "Óscar Puente",
            "revision": 1, "status": "published",
            "explanation": "Óscar Puente es tendencia por su dimisión.",
            "explained_at": "2026-11-05T08:00:00Z",
        }
        auto_reentry = {
            "id": "random-new-id", "name": "Oscar Puente",
            "status": "inactive", "auto_queued": True,
        }
        history = policy.treated_terms([old, auto_reentry], [], [], [])
        self.assertIn("oscar puente", history)
        self.assertFalse(policy.should_reopen_from_radar("Óscar Puente", history, auto_reentry))

    def test_compacted_explained_catalog_still_protects_closed_decision(self):
        old = {"id": "p1", "name": "Óscar Puente", "status": "inactive"}
        delivery = {"event_id": "p1", "status": "published"}
        history = policy.treated_terms([old], [], [delivery], [])
        self.assertFalse(policy.should_reopen_from_radar("Oscar Puente", history, None))

    def test_manual_new_verified_episode_can_be_requested(self):
        known = {"oscar puente"}
        manual = {
            "name": "Óscar Puente",
            "request_source": "telegram_private_deeplink_native",
            "status": "preparing", "auto_queued": False,
        }
        self.assertTrue(policy.should_reopen_from_radar("Óscar Puente", known, manual))

    def test_unverified_processing_only_does_not_block_first_episode(self):
        requests = [{"id": "new", "name": "New Trend",
                     "status": "preparing", "auto_queued": True},
                    {"id": "problem", "name": "Old Failed", "status": "problematic"}]
        history = policy.treated_terms(requests, [])
        self.assertNotIn("new trend", history)
        self.assertTrue(policy.should_reopen_from_radar("New Trend", history, requests[0]))

    def test_snapshot_explained_term_blocks_reentry_without_requests(self):
        explained = [{"name": "Óscar Puente", "explained_at": "2026-11-05T08:00:00Z",
                      "explanation": "Por la dimisión de hoy"}]
        history = policy.treated_terms([], explained)
        self.assertFalse(policy.should_reopen_from_radar("Oscar Puente", history, None))

    def test_red_review_job_is_not_evidence_of_treated_trend(self):
        history = policy.treated_terms([
            {"id": "job", "name": "New Trend", "status": "explained",
             "red_review_request": True, "explained_at": "2026-11-05T08:00:00Z",
             "explanation": "result"}
        ], [])
        self.assertNotIn("new trend", history)


if __name__ == "__main__":
    unittest.main()
