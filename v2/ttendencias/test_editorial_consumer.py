import unittest
from datetime import datetime, timedelta, timezone
from v2.ttendencias.editorial_consumer import claim, complete, recover
from v2.ttendencias.editorial_queue import sync_queue
from v2.ttendencias.detect_changes import build

NOW = datetime(2026, 11, 13, 0, 0, tzinfo=timezone.utc)


def queue():
    cap = {"mode": "live", "country": "ES", "count": 30,
           "source": "https://getdaytrends.com/es/spain/",
           "observed_at": NOW.isoformat(),
           "top30": [f"Trend {i}" for i in range(1, 31)]}
    hist = build(cap, now=NOW)["state"]
    return sync_queue(hist)["state"]


class ConsumerTests(unittest.TestCase):
    def test_claim_is_explicit_and_one_per_capacity(self):
        q = queue()
        nxt, jobs, _ = claim(q, worker_id="test", now=NOW, capacity=1)
        self.assertEqual(len(jobs), 1)
        self.assertEqual(sum(x["status"] == "in_progress" for x in nxt["items"].values()), 1)
        self.assertEqual(sum(x["status"] == "pending" for x in q["items"].values()), 30)

    def test_second_claim_cannot_duplicate(self):
        q, first, _ = claim(queue(), worker_id="one", now=NOW, capacity=1)
        q2, second, _ = claim(q, worker_id="two", now=NOW + timedelta(minutes=1), capacity=1)
        self.assertEqual(second, [])
        self.assertEqual(q2["items"][first[0]["trend_id"]]["lease"]["token"], first[0]["token"])

    def test_capacity_three_and_no_overflow(self):
        q, first, _ = claim(queue(), worker_id="one", now=NOW, capacity=3)
        self.assertEqual(len(first), 3)
        _, second, _ = claim(q, worker_id="two", now=NOW, capacity=3)
        self.assertEqual(second, [])

    def test_valid_completion(self):
        q, jobs, _ = claim(queue(), worker_id="one", now=NOW)
        j = jobs[0]
        done = complete(q, trend_id=j["trend_id"], revision=j["revision"],
                        token=j["token"], text="Explicación contrastada",
                        now=NOW + timedelta(minutes=2))
        self.assertEqual(done["items"][j["trend_id"]]["status"], "ready")
        self.assertEqual(done["items"][j["trend_id"]]["text"], "Explicación contrastada")
        with self.assertRaises(ValueError):
            complete(done, trend_id=j["trend_id"], revision=j["revision"],
                     token=j["token"], text="Duplicado", now=NOW + timedelta(minutes=3))

    def test_wrong_token_and_empty_text(self):
        q, jobs, _ = claim(queue(), worker_id="one", now=NOW)
        j = jobs[0]
        with self.assertRaises(ValueError):
            complete(q, trend_id=j["trend_id"], revision=1, token="fake", text="Texto", now=NOW)
        with self.assertRaises(ValueError):
            complete(q, trend_id=j["trend_id"], revision=1, token=j["token"], text=" ", now=NOW)

    def test_expiry_reopens_and_rejects_old_result(self):
        q, jobs, _ = claim(queue(), worker_id="one", now=NOW)
        j = jobs[0]
        later = NOW + timedelta(minutes=16)
        recovered, events = recover(q, now=later)
        self.assertEqual(len(events), 1)
        self.assertEqual(recovered["items"][j["trend_id"]]["status"], "pending")
        with self.assertRaises(ValueError):
            complete(recovered, trend_id=j["trend_id"], revision=1,
                     token=j["token"], text="Tardío", now=later)

    def test_max_three_attempts_then_stop(self):
        q = queue()
        for i in range(3):
            q, jobs, _ = claim(q, worker_id="one", now=NOW + timedelta(minutes=i * 16))
            self.assertTrue(jobs)
        q, events = recover(q, now=NOW + timedelta(minutes=48))
        self.assertEqual(len(events), 1)
        self.assertEqual(q["items"][jobs[0]["trend_id"]]["status"], "cancelled")

    def test_review_pending_claim(self):
        q = queue()
        tid = next(iter(q["items"]))
        q["items"][tid]["status"] = "review_pending"
        q["items"][tid]["revision"] = 2
        _, jobs, _ = claim(q, worker_id="one", now=NOW)
        self.assertTrue(jobs)
        self.assertEqual(jobs[0]["revision"], 2)

    def test_reject_wrong_queue(self):
        q = queue()
        q["effects_enabled"] = True
        with self.assertRaises(ValueError):
            claim(q, worker_id="one", now=NOW)


if __name__ == "__main__":
    unittest.main()
