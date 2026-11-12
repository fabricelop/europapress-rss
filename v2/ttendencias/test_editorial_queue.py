import unittest
from datetime import datetime, timedelta, timezone
from v2.ttendencias.detect_changes import build
from v2.ttendencias.editorial_queue import sync_queue

BASE=datetime(2026, 11, 12, 22, 0, tzinfo=timezone.utc)
NAMES=[f"Trend {i}" for i in range(1,31)]


def capture(m, names=None):
    return {"mode":"live","country":"ES","count":30,"source":"https://getdaytrends.com/es/spain/",
            "observed_at":(BASE+timedelta(minutes=m)).isoformat(),"top30":names or NAMES}


def history(m, names=None, previous=None):
    return build(capture(m, names), previous, now=BASE+timedelta(minutes=m))["state"]


class EditorialQueueTests(unittest.TestCase):
    def test_initial_queue_one_per_id(self):
        h=history(0)
        r=sync_queue(h)
        self.assertEqual(r["state"]["pending_count"],30)
        self.assertEqual(len(r["state"]["items"]),30)
        self.assertEqual(len({x["trend_id"] for x in r["state"]["items"].values()}),30)
        self.assertFalse(r["state"]["effects_enabled"])

    def test_unchanged_and_rank_changes_idempotent(self):
        h=history(0)
        first=sync_queue(h)["state"]
        self.assertEqual(sync_queue(h,first)["changes"],[])
        moved=history(10,NAMES[1:]+NAMES[:1],h)
        later=sync_queue(moved,first)
        self.assertEqual(later["changes"],[])
        self.assertEqual(later["state"]["pending_count"],30)

    def test_new_entry_only_one_new_request(self):
        h=history(0)
        q=sync_queue(h)["state"]
        later=history(10,["New"]+NAMES[:29],h)
        nxt=sync_queue(later,q)
        self.assertEqual(len(nxt["changes"]),1)
        self.assertEqual(len(nxt["state"]["items"]),31)

    def test_short_return_no_new_revision(self):
        h=history(0)
        q=sync_queue(h)["state"]
        tid=h["topics"]["trend 30"]["trend_id"]
        q["items"][tid].update(status="published",text="Explicación existente")
        absent=history(10,["New"]+NAMES[:29],h)
        q2=sync_queue(absent,q)["state"]
        back=history(20,NAMES,absent)
        r=sync_queue(back,q2)
        self.assertEqual(r["state"]["items"][tid]["revision"],1)
        self.assertEqual(r["state"]["items"][tid]["status"],"published")

    def test_over_24h_review_keeps_id_and_text_backup(self):
        h=history(0)
        q=sync_queue(h)["state"]
        tid=h["topics"]["trend 30"]["trend_id"]
        q["items"][tid].update(status="published",text="Explicación existente")
        absent=history(10,["New"]+NAMES[:29],h)
        q2=sync_queue(absent,q)["state"]
        back=history(10+24*60+1,NAMES,absent)
        r=sync_queue(back,q2)
        item=r["state"]["items"][tid]
        self.assertEqual(item["revision"],2)
        self.assertEqual(item["status"],"review_pending")
        self.assertEqual(item["reason"],"return_after_24h")
        self.assertEqual(item["previous_explanation"]["text"],"Explicación existente")
        self.assertEqual(item["trend_id"],tid)
        self.assertFalse(sync_queue(back,r["state"])["changes"])

    def test_pending_not_duplicated_on_reentry(self):
        h=history(0);q=sync_queue(h)["state"]
        absent=history(10,["New"]+NAMES[:29],h)
        q2=sync_queue(absent,q)["state"]
        back=history(10+24*60+1,NAMES,absent)
        r=sync_queue(back,q2)
        tid=h["topics"]["trend 30"]["trend_id"]
        self.assertEqual(r["state"]["items"][tid]["revision"],1)
        self.assertEqual(r["state"]["items"][tid]["status"],"pending")

    def test_editorial_change_requires_explicit_signal(self):
        h=history(0);q=sync_queue(h)["state"]
        tid=h["topics"]["trend 3"]["trend_id"]
        q["items"][tid].update(status="ready",text="Hecho")
        changed=sync_queue(h,q,changed_explanations={tid})
        self.assertEqual(changed["state"]["items"][tid]["status"],"review_pending")
        self.assertEqual(changed["state"]["items"][tid]["reason"],"changed_explanation")
        self.assertEqual(changed["state"]["items"][tid]["revision"],2)
        self.assertEqual(sync_queue(h,changed["state"])["changes"],[])

    def test_reject_unknown_id_and_stale_history(self):
        h=history(0);q=sync_queue(h)["state"]
        with self.assertRaises(ValueError):
            sync_queue(h,q,changed_explanations={"unknown"})
        newer=history(10,previous=h)
        q2=sync_queue(newer,q)["state"]
        with self.assertRaises(ValueError):
            sync_queue(h,q2)


if __name__=="__main__":
    unittest.main()
