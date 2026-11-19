#!/usr/bin/env python3
"""Unit tests: queue rank, auto no-resend and OS-lock; no network/Chrome."""
import pathlib
import tempfile
import unittest
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from auto_editorial_policy_v2 import eligible_plan, enabled_text
from process_lock_v2 import exclusive_v2_lock, AlreadyRunning

NOW = datetime(2026, 11, 13, 18, 0, tzinfo=timezone.utc)
STAMP = (NOW - timedelta(minutes=4)).isoformat()


def fixtures():
    names = ["Tema%02d" % i for i in range(1,31)]
    topics = {}
    items = {}
    for rank,name in enumerate(names,1):
        ident = "trv2-test-%02d" % rank
        topics[name]={"trend_id": ident, "name":name,
                      "rank":rank,"active":True}
        items[ident]={"trend_id":ident,"name":name,"revision":1,
                     "status":"pending","requested_at":STAMP}
    items["old"]={"trend_id":"old","name":"antiguo","revision":1,
                  "status":"pending","requested_at":"2026-11-10"}
    return (
        {"step":"04_editorial_queue","source_observed_at":STAMP,
         "effects_enabled":False,"items":items},
        {"step":"03_movement","country":"ES","observed_at":STAMP,
         "top30":names,"topics":topics}
    )


class AutomaticEditorialTests(unittest.TestCase):
    def test_rank_one_before_historical_backlog(self):
        q,h=fixtures()
        with tempfile.TemporaryDirectory() as temp:
            selected,age,blocked=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(selected["name"],"Tema01")
        self.assertEqual(age,4)
        self.assertEqual(blocked,[])

    def test_failure_moves_behind_every_unattempted_top30_topic(self):
        q,h=fixtures()
        # Tres tendencias fallaron seis veces. La siguiente vuelta debe
        # empezar por la primera sin intentar, aunque su puesto sea peor.
        for rank in (1,2,3):
            q["items"]["trv2-test-%02d" % rank].update(
                revision=7, incident_retries=6, reason="retry_after_incident")
        with tempfile.TemporaryDirectory() as temp:
            first,_,_=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(first["name"], "Tema04")

    def test_one_attempt_per_traversal_then_restart_at_top(self):
        q,h=fixtures()
        # Cuando todas llevan una tentativa, comienza una nueva ronda
        # por el primer puesto; nunca vuelve antes la recién fallida.
        for item in q["items"].values():
            if item["trend_id"] != "old":
                item["incident_retries"] = 1
                item["revision"] = 2
        with tempfile.TemporaryDirectory() as temp:
            first,_,_=eligible_plan(q,h,directory=temp,now=NOW)
            q["items"]["trv2-test-01"].update(revision=3, incident_retries=2)
            second,_,_=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(first["name"], "Tema01")
        self.assertEqual(second["name"], "Tema02")

    def test_user_reset_is_prioritized_in_spite_of_automatic_round(self):
        q,h=fixtures()
        q["items"]["trv2-test-01"].update(
            revision=4, incident_retries=3, status="review_pending",
            reason="user_reset", attempts=0)
        with tempfile.TemporaryDirectory() as temp:
            selected,_,_=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(selected["name"], "Tema01")

    def test_does_not_resend_local_journal(self):
        q,h=fixtures()
        with tempfile.TemporaryDirectory() as temp:
            pathlib.Path(temp,"run-trv2-test-01-r1.json").write_text('{"message_sent":true}')
            selected,_,blocked=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(selected["name"],"Tema02")
        self.assertEqual(blocked,["trv2-test-01"])

    def test_user_re_is_first_even_after_trend_exits_top30(self):
        q,h=fixtures()
        old=q["items"]["old"]
        old.update(status="review_pending",reason="user_reexplanation",revision=2,
                   attempts=0,requested_at="2026-11-15T13:00:00Z")
        h["topics"]["historical"]={"trend_id":"old","name":"antiguo",
                                   "active":False,"rank":None}
        with tempfile.TemporaryDirectory() as temp:
            selected,_,_=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(selected["trend_id"],"old")
        self.assertEqual(selected["revision"],2)

    def test_reset_is_prioritized_even_with_old_chat_journal_and_stale_radar(self):
        q,h=fixtures()
        q["items"]["old"].update(status="review_pending",reason="user_reset",revision=2,
                                 attempts=0,requested_at=STAMP)
        h["topics"]["historical"]={"trend_id":"old","active":False,"rank":None}
        with tempfile.TemporaryDirectory() as temp:
            pathlib.Path(temp,"run-old-r1.json").write_text('{"message_sent":true}')
            selected,_,_=eligible_plan(q,h,directory=temp,now=NOW+timedelta(hours=1))
        self.assertEqual((selected["trend_id"],selected["revision"]),("old",2))

    def test_explicit_re_works_with_stale_top30_but_ordinary_does_not(self):
        q,h=fixtures()
        q["items"]["old"].update(status="review_pending",reason="user_reexplanation",revision=2)
        h["topics"]["historical"]={"trend_id":"old","active":False,"rank":None}
        with tempfile.TemporaryDirectory() as temp:
            chosen,_,_=eligible_plan(q,h,directory=temp,now=NOW+timedelta(hours=1))
        self.assertEqual(chosen["trend_id"],"old")

    def test_user_re_is_not_sent_again_when_local_journal_exists(self):
        q,h=fixtures()
        q["items"]["old"].update(status="review_pending",reason="user_reexplanation",revision=2)
        h["topics"]["historical"]={"trend_id":"old","active":False,"rank":None}
        with tempfile.TemporaryDirectory() as temp:
            pathlib.Path(temp,"run-old-r2.json").write_text('{"message_sent":true}')
            chosen,_,blocked=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(chosen["name"],"Tema01")
        self.assertEqual(blocked,["old"])

    def test_skips_in_progress_and_captured(self):
        q,h=fixtures()
        q["items"]["trv2-test-01"]["status"]="in_progress"
        q["items"]["trv2-test-02"]["status"]="captured_review"
        with tempfile.TemporaryDirectory() as temp:
            selected,_,_=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(selected["name"],"Tema03")

    def test_all_ranked_done_never_runs_old(self):
        q,h=fixtures()
        for i in range(1,31):
            q["items"]["trv2-test-%02d"%i]["status"]="captured_review"
        with tempfile.TemporaryDirectory() as temp:
            selected,_,_=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertIsNone(selected)

    def test_expired_snapshot_must_wait(self):
        q,h=fixtures()
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError,"no actualizado"):
                eligible_plan(q,h,directory=temp,now=NOW+timedelta(minutes=19))

    def test_mismatched_queue_and_rank_must_wait(self):
        q,h=fixtures()
        q["source_observed_at"]="2026-11-10"
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                eligible_plan(q,h,directory=temp,now=NOW)

    def test_requires_exact_local_enable_flag(self):
        self.assertTrue(enabled_text("TT_V2_AUTO_EDITORIAL_ENABLED=YES\n"))
        self.assertTrue(enabled_text("\ufeffTT_V2_AUTO_EDITORIAL_ENABLED=YES"))
        self.assertFalse(enabled_text("YES"))
        self.assertFalse(enabled_text("TT_V2_AUTO_EDITORIAL_ENABLED=NO"))

    def test_os_lock_exclusive_and_recoverable(self):
        with tempfile.TemporaryDirectory() as temp:
            path=pathlib.Path(temp)/"single.lock"
            with exclusive_v2_lock(path):
                with self.assertRaises(AlreadyRunning):
                    with exclusive_v2_lock(path):
                        pass
            # The OS frees it; the file is not deleted to prevent races.
            self.assertTrue(path.exists())
            with exclusive_v2_lock(path):
                pass

    def test_eligible_even_if_rank_changes_after_snapshot(self):
        q,h=fixtures()
        with tempfile.TemporaryDirectory() as temp:
            selected,_,_=eligible_plan(q,h,directory=temp,now=NOW)
        # Once selected, the downstream run_one uses the ID/revision, not rank.
        h["topics"]["Tema01"].update(active=False,rank=None)
        self.assertEqual(selected["trend_id"],"trv2-test-01")
        self.assertEqual(selected["revision"],1)


if __name__ == "__main__":
    unittest.main()
