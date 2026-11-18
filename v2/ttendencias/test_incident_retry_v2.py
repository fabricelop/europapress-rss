#!/usr/bin/env python3
"""Incident reset tests; never open Chrome, call GitHub or send a message."""
import copy
import pathlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from incident_retry_v2 import eligible_incident, ranked_incident, restart_as_new_revision
from auto_editorial_policy_v2 import eligible_plan

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

    def test_new_revision_reenters_top30_by_rank_with_fresh_journal_name(self):
        q, h = sample()
        ident = "trv2-%024x" % 1
        q["items"][ident].update(status="capture_recovery",
                                  updated_at=(NOW-timedelta(hours=1)).isoformat(),
                                  send_intent={"token":"OLD"})
        newer = restart_as_new_revision(q, ident, now=NOW,
            chrome_clear=True, recovery_checked=True)
        with tempfile.TemporaryDirectory() as path:
            pathlib.Path(path, "run-" + ident + "-r1.json").write_text("old")
            selected, age, blocked = eligible_plan(newer, h, directory=path, now=NOW)
        self.assertEqual(selected["trend_id"], ident)
        self.assertEqual(selected["revision"], 2)
        self.assertEqual(blocked, [])
        self.assertEqual(age, 3)

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

    def test_explicit_user_retry_after_exhaustion_starts_fresh_cycle(self):
        q, _ = sample()
        ident = "trv2-%024x" % 1
        q["items"][ident].update(status="capture_recovery", revision=3,
            incident_retries=2, updated_at=(NOW-timedelta(hours=1)).isoformat(),
            manual_retry_requested_at=STAMP,
            manual_retry_instructions_pending="Contrasta de nuevo el resultado antes de redactar.")
        self.assertTrue(eligible_incident(q["items"][ident], now=NOW))
        newer = restart_as_new_revision(q, ident, now=NOW,
                                        chrome_clear=True, recovery_checked=True)
        item = newer["items"][ident]
        self.assertEqual(item["revision"], 4)
        self.assertEqual(item["incident_retries"], 0)
        self.assertEqual(item["status"], "pending")
        self.assertIn("Contrasta", item["manual_retry_instructions"])
        self.assertNotIn("manual_retry_requested_at", item)
        self.assertFalse(eligible_incident(item, now=NOW))

    def test_historical_manual_retry_is_selected_after_current_top30(self):
        q, h = sample()
        ident = "trv2-%024x" % 31
        h["topics"]["Fuera"] = {"name":"Fuera","active":False,"rank":None,"trend_id":ident}
        q["items"][ident] = {"trend_id": ident, "name": "Fuera", "revision": 2,
            "status":"capture_recovery", "incident_retries": 2,
            "manual_retry_requested_at": STAMP,
            "updated_at": (NOW-timedelta(hours=1)).isoformat()}
        match, _ = ranked_incident(q, h, now=NOW)
        self.assertEqual(match["trend_id"], ident)

    def test_incident_rex_hints_are_used_only_after_safe_recovery_check(self):
        q, _ = sample()
        ident = "trv2-%024x" % 1
        hints = "Revisar los mensajes de X y contrastar fechas y personas."
        q["items"][ident].update(status="capture_recovery", revision=2,
                                  updated_at=(NOW-timedelta(hours=1)).isoformat(),
                                  incident_review_hints_pending=hints)
        with self.assertRaises(ValueError):
            restart_as_new_revision(q, ident, now=NOW, chrome_clear=True,
                                    recovery_checked=False)
        newer = restart_as_new_revision(q, ident, now=NOW,
            chrome_clear=True, recovery_checked=True)
        item = newer["items"][ident]
        self.assertEqual(item["revision"], 3)
        self.assertEqual(item["status"], "review_pending")
        self.assertEqual(item["review_mode"], "x")
        self.assertEqual(item["review_hints"], hints.strip())
        self.assertNotIn("incident_review_hints_pending", item)
        self.assertEqual(q["items"][ident]["revision"], 2)

    def test_incident_retry_preserves_existing_rex_context_without_new_hints(self):
        q, _ = sample()
        ident = "trv2-%024x" % 1
        q["items"][ident].update(status="capture_recovery", revision=2,
            review_mode="x", review_hints="Investigar tema con contexto verificado.",
            updated_at=(NOW-timedelta(hours=1)).isoformat())
        newer = restart_as_new_revision(q, ident, now=NOW,
            chrome_clear=True, recovery_checked=True)
        item = newer["items"][ident]
        self.assertEqual(item["status"], "pending")
        self.assertEqual(item["review_mode"], "x")
        self.assertEqual(item["review_hints"], "Investigar tema con contexto verificado.")

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

    def test_deferred_owner_re_x_survives_only_after_safe_incident_restart(self):
        q,_=sample()
        ident="trv2-%024x" % 1
        hints="Contrastar el vídeo y su fecha en X antes de redactar."
        q["items"][ident].update(status="capture_recovery",
            updated_at=(NOW-timedelta(hours=1)).isoformat(),
            review_mode="standard",
            deferred_re_request={"base_revision":1,"mode":"x","hints":hints},
            manual_retry_requested_at=STAMP)
        with self.assertRaises(ValueError):
            restart_as_new_revision(q,ident,now=NOW,chrome_clear=False,recovery_checked=True)
        nxt=restart_as_new_revision(q,ident,now=NOW,chrome_clear=True,recovery_checked=True)
        row=nxt["items"][ident]
        self.assertEqual(row["status"],"review_pending")
        self.assertEqual(row["review_hints"],hints)
        self.assertNotIn("deferred_re_request",row)

    def test_deferred_standard_re_clears_previous_x_hints(self):
        q,_=sample()
        ident="trv2-%024x" % 1
        q["items"][ident].update(status="capture_recovery",
            updated_at=(NOW-timedelta(hours=1)).isoformat(),
            review_mode="x",review_hints="Anterior pista para la investigación.",
            deferred_re_request={"base_revision":1,"mode":"standard","hints":""},
            manual_retry_requested_at=STAMP)
        nxt=restart_as_new_revision(q,ident,now=NOW,chrome_clear=True,recovery_checked=True)
        row=nxt["items"][ident]
        self.assertNotIn("review_mode",row)
        self.assertNotIn("review_hints",row)


if __name__ == "__main__":
    unittest.main()
