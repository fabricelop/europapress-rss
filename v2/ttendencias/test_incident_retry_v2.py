#!/usr/bin/env python3
"""Incident reset tests; never open Chrome, call GitHub or send a message."""
import copy
import pathlib
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from incident_retry_v2 import eligible_incident, ranked_incident, restart_as_new_revision

NOW = datetime(2026, 11, 13, 20, 40, tzinfo=timezone.utc)
STAMP = (NOW - timedelta(minutes=3)).isoformat()


def sample():
    names = ["Tema %02d" % n for n in range(1, 31)]
    topics = {}
    items = {}
    for rank, name in enumerate(names, 1):
        ident = "trv2-%024x" % rank
        topics[name] = {"name": name, "rank": rank, "trend_id": ident, "active": True}
        items[ident] = {"trend_id": ident, "name": name, "revision": 1,
                        "status": "pending", "requested_at": STAMP, "updated_at": STAMP}
    queue = {"step": "04_editorial_queue", "country": "ES",
             "effects_enabled": False, "source_observed_at": STAMP,
             "items": items, "pending_ids": list(items), "pending_count": 30}
    history = {"step": "03_movement", "country": "ES", "observed_at": STAMP,
               "top30": names, "topics": topics}
    return queue, history


class IncidentRetryTests(unittest.TestCase):
    def test_expired_leased_job_is_eligible(self):
        q, _ = sample()
        x = q["items"]["trv2-%024x" % 1]
        x["status"] = "in_progress"
        x["lease"] = {"expires_at": (NOW - timedelta(minutes=12)).isoformat()}
        self.assertTrue(eligible_incident(x, now=NOW))

    def test_active_lease_never_retried(self):
        q, _ = sample()
        x = q["items"]["trv2-%024x" % 1]
        x["status"] = "in_progress"
        x["lease"] = {"expires_at": (NOW - timedelta(minutes=3)).isoformat()}
        self.assertFalse(eligible_incident(x, now=NOW))

    def test_recovery_status_waits_eight_minutes(self):
        q, _ = sample()
        x = q["items"]["trv2-%024x" % 1]
        x["status"] = "capture_recovery"
        x["updated_at"] = (NOW - timedelta(minutes=6)).isoformat()
        self.assertFalse(eligible_incident(x, now=NOW))
        x["updated_at"] = (NOW - timedelta(minutes=14)).isoformat()
        self.assertTrue(eligible_incident(x, now=NOW))

    def test_rank_one_incident_selected_before_rank_two(self):
        q, h = sample()
        for rank in (1, 2):
            x = q["items"]["trv2-%024x" % rank]
            x["status"] = "capture_recovery"
            x["updated_at"] = (NOW - timedelta(minutes=20)).isoformat()
        match, age = ranked_incident(q, h, now=NOW)
        self.assertEqual(match["name"], "Tema 01")
        self.assertEqual(age, 3)

    def test_guard_requires_both_close_and_recovery_check(self):
        q, _ = sample()
        ident = "trv2-%024x" % 1
        q["items"][ident].update(status="capture_recovery",
                                  updated_at=(NOW-timedelta(minutes=20)).isoformat())
        with self.assertRaises(ValueError):
            restart_as_new_revision(q, ident, now=NOW, chrome_clear=False,
                                    recovery_checked=True)
        with self.assertRaises(ValueError):
            restart_as_new_revision(q, ident, now=NOW, chrome_clear=True,
                                    recovery_checked=False)

    def test_retry_is_new_revision_preserving_previous_chat_and_send_evidence(self):
        q, _ = sample()
        original = copy.deepcopy(q)
        ident = "trv2-%024x" % 1
        q["items"][ident].update(
            status="in_progress", attempts=1,
            lease={"expires_at": (NOW-timedelta(minutes=20)).isoformat(),
                   "started_at": "2026-11-13T18:00:00Z"},
            send_intent={"token": "OLD_SECRET", "at": "2026-11-13T18:10:00Z"})
        new = restart_as_new_revision(
            q, ident, now=NOW, chrome_clear=True, recovery_checked=True,
            previous_chat_url="https://chatgpt.com/c/prior-unique-chat-id")
        x = new["items"][ident]
        self.assertEqual(x["revision"], 2)
        self.assertEqual(x["status"], "pending")
        self.assertEqual(x["incident_retries"], 1)
        self.assertEqual(x["attempts"], 0)
        self.assertFalse(x.get("send_intent"))
        self.assertFalse(x.get("lease"))
        self.assertEqual(x["previous_attempts"][0]["revision"], 1)
        self.assertEqual(x["previous_attempts"][0]["chat_url"],
                         "https://chatgpt.com/c/prior-unique-chat-id")
        self.assertNotIn("OLD_SECRET", str(new))
        self.assertEqual(original["items"][ident]["status"], "pending")
        self.assertEqual(q["items"][ident]["revision"], 1)

    def test_retry_limit_prevents_infinite_loop(self):
        q, _ = sample()
        ident = "trv2-%024x" % 1
        q["items"][ident].update(status="capture_recovery",
                                  incident_retries=2,
                                  updated_at=(NOW-timedelta(hours=1)).isoformat())
        self.assertFalse(eligible_incident(q["items"][ident], now=NOW))
        with self.assertRaises(ValueError):
            restart_as_new_revision(q, ident, now=NOW,
                                    chrome_clear=True, recovery_checked=True)

    def test_verified_capture_never_reset(self):
        q, _ = sample()
        ident = "trv2-%024x" % 1
        q["items"][ident].update(status="capture_recovery",
                                  capture={"verified_complete": True},
                                  updated_at=(NOW-timedelta(hours=1)).isoformat())
        self.assertFalse(eligible_incident(q["items"][ident], now=NOW))

    def test_old_history_refused(self):
        q, h = sample()
        with self.assertRaises(ValueError):
            ranked_incident(q, h, now=NOW+timedelta(minutes=21))

    def test_historical_incident_out_of_top30_not_priority(self):
        q, h = sample()
        q["items"]["older"] = {"name": "Fuera", "trend_id": "older",
                                "revision": 1, "status": "capture_recovery",
                                "updated_at": (NOW-timedelta(hours=3)).isoformat()}
        candidate, _ = ranked_incident(q, h, now=NOW)
        self.assertIsNone(candidate)

if __name__ == "__main__":
    unittest.main()
