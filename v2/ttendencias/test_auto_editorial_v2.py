#!/usr/bin/env python3
"""Unit tests: queue rank, auto no-resend and OS-lock; no network/Chrome."""
import pathlib
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

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

    def test_does_not_resend_local_journal(self):
        q,h=fixtures()
        with tempfile.TemporaryDirectory() as temp:
            pathlib.Path(temp,"run-trv2-test-01-r1.json").write_text('{"message_sent":true}')
            selected,_,blocked=eligible_plan(q,h,directory=temp,now=NOW)
        self.assertEqual(selected["name"],"Tema02")
        self.assertEqual(blocked,["trv2-test-01"])

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
