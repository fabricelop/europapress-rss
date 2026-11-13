#!/usr/bin/env python3
"""Top30 V2: pruebas deterministas sin navegador ni red."""
import copy
import unittest
from datetime import datetime, timedelta, timezone
from select_current_top30_v2 import select_current_top30

NOW = datetime(2026,11,13,17,0, tzinfo=timezone.utc)
STAMP = (NOW - timedelta(minutes=5)).isoformat()

def fixtures():
    names = ["Tema %02d" % x for x in range(1,31)]
    topics = {}
    items = {}
    for i, name in enumerate(names, 1):
        ident = "trend-%02d" % i
        topics[name] = {"rank":i,"name":name,"active":True,"trend_id":ident}
        items[ident] = {"trend_id":ident,"name":name,"revision":1,
                        "status":"pending","requested_at":"2026-11-13T12:00:00Z"}
    # Este antiguo trabajo lleva más tiempo pendiente, pero ya no es Top30.
    items["historical"] = {"trend_id":"historical","name":"Tema anterior",
                          "revision":1,"status":"pending",
                          "requested_at":"2026-11-10T00:00:00Z"}
    return (
       {"step":"04_editorial_queue","effects_enabled":False,
        "source_observed_at":STAMP,"items":items},
       {"step":"03_movement","country":"ES","observed_at":STAMP,
        "top30":names,"topics":topics}
    )

class TestCurrentTop30(unittest.TestCase):
    def test_current_rank_beats_old_backlog(self):
        q,h=fixtures()
        selected, age=select_current_top30(q,h,2,now=NOW)
        self.assertEqual([x["name"] for x in selected],["Tema 01","Tema 02"])
        self.assertEqual(age,5.0)

    def test_prioritizes_next_current_if_first_done(self):
        q,h=fixtures()
        q["items"]["trend-01"]["status"]="captured_review"
        selected,_=select_current_top30(q,h,2,now=NOW)
        self.assertEqual([x["trend_id"] for x in selected],["trend-02","trend-03"])

    def test_no_history_fallback_when_top30_done(self):
        q,h=fixtures()
        for i in range(1,31):
            q["items"]["trend-%02d"%i]["status"]="captured_review"
        selected,_=select_current_top30(q,h,2,now=NOW)
        self.assertEqual(selected,[])

    def test_stale_capture_refused(self):
        q,h=fixtures()
        with self.assertRaisesRegex(ValueError,"no actualizado"):
            select_current_top30(q,h,2,now=NOW+timedelta(minutes=16))

    def test_mismatched_history_queue_refused(self):
        q,h=fixtures()
        q["source_observed_at"]="2026-11-12T00:00:00+00:00"
        with self.assertRaises(ValueError):
            select_current_top30(q,h,2,now=NOW)

    def test_duplicate_rank_refused(self):
        q,h=fixtures()
        h["topics"]["Tema 02"]["rank"]=1
        with self.assertRaisesRegex(ValueError,"duplicado"):
            select_current_top30(q,h,2,now=NOW)

    def test_no_send_intent_or_lease(self):
        q,h=fixtures()
        q["items"]["trend-01"]["send_intent"]={"token":"sent"}
        q["items"]["trend-02"]["lease"]={"token":"held"}
        selected,_=select_current_top30(q,h,2,now=NOW)
        self.assertEqual([x["trend_id"] for x in selected],["trend-03","trend-04"])

    def test_effects_enabled_refused(self):
        q,h=fixtures()
        q["effects_enabled"]=True
        with self.assertRaises(ValueError):
            select_current_top30(q,h,2,now=NOW)

    def test_incomplete_top30_refused(self):
        q,h=fixtures()
        h["top30"].pop()
        with self.assertRaisesRegex(ValueError,"incompleto"):
            select_current_top30(q,h,2,now=NOW)

    def test_no_revisions_or_names_mutated(self):
        q,h=fixtures()
        q_copy=copy.deepcopy(q); h_copy=copy.deepcopy(h)
        select_current_top30(q,h,3,now=NOW)
        self.assertEqual(q,q_copy)
        self.assertEqual(h,h_copy)

if __name__ == "__main__":
    unittest.main()
