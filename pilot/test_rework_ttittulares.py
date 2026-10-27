"""Regression checks for the pure TTActualidad full-news rewrite request.

Runs only synthetic data. Never reads/writes main or dispatches a workflow.
"""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rework_ttittulares import rework_ready_news


class ReworkReadyNewsTest(unittest.TestCase):
    ID = "test-ready-abcd1234"

    def fixture(self):
        prepared = {
            "items": [
                {
                    "event_id": self.ID, "title": "Noticia de ejemplo",
                    "status": "READY", "revision": 4,
                    "url": "https://example.org/story", "source_count": 4,
                    "sources": ["Agencia A", "Diario B", "Radio C", "Diario D"],
                    "explanation": "Texto ANTIGUO",
                    "factual_summary": "Hechos ANTIGUOS",
                    "tweet": {"text": "Tweet ANTIGUO", "remate": "Remate ANTIGUO"},
                    "archive_image": {"url": "https://example.org/old.jpg"},
                },
                {"event_id": "other-ready", "revision": 2,
                 "title": "Otra noticia", "status": "READY"},
            ],
            "count": 2,
        }
        queue = {
            "items": [{"event_id": self.ID, "revision": 4, "status": "READY"},
                      {"event_id": "other-processing", "revision": 1,
                       "status": "PROCESSING"}],
            "count": 1,
        }
        mirror = {"items": [{"event_id": "other-processing", "revision": 1,
                             "status": "PROCESSING"}]}
        decisions = {"items": []}
        return prepared, queue, mirror, decisions

    def request(self, *fixture):
        return rework_ready_news(self.ID, 4, *fixture,
                                 now="2026-10-27T12:00:00+00:00")

    def test_atomic_rework_requests_new_revision_and_ignores_old_text(self):
        output = self.request(*self.fixture())
        self.assertEqual(set(output), {
            "ttittulares/prepared.json",
            "ttittulares/editorial-queue.json",
            "telegram/editorial-processing.json",
        })
        prepared = output["ttittulares/prepared.json"]
        waiting = prepared["items"][0]
        self.assertEqual(waiting["revision"], 4)
        self.assertTrue(waiting["rewrite_pending"])
        self.assertEqual(waiting["rewrite_target_revision"], 5)
        self.assertEqual(waiting["rewrite_scope"], "full")
        self.assertTrue(waiting["reinvestigate"])
        self.assertIsNone(waiting["preserved_editorial"])
        self.assertEqual(prepared["count"], 1)
        work = output["ttittulares/editorial-queue.json"]
        self.assertEqual(work["count"], 2)
        rows = [x for x in work["items"] if x["event_id"] == self.ID]
        self.assertEqual(len(rows), 1)
        new = rows[0]
        self.assertEqual((new["revision"], new["status"], new["selection_mode"]),
                         (5, "UPDATE_PROCESSING", "REWRITE"))
        self.assertTrue(new["reinvestigate"])
        for old in ("Texto ANTIGUO", "Hechos ANTIGUOS", "Tweet ANTIGUO",
                    "Remate ANTIGUO", "old.jpg"):
            self.assertNotIn(old, json.dumps(new, ensure_ascii=False))
        self.assertNotIn("tweet", new)
        self.assertNotIn("explanation", new)
        self.assertNotIn("archive_image", new)
        self.assertEqual(output["telegram/editorial-processing.json"]["items"][-1], new)
        self.assertEqual(prepared["items"][1]["event_id"], "other-ready")
        self.assertEqual(work["items"][0]["event_id"], "other-processing")

    def test_repeat_is_idempotent(self):
        output = self.request(*self.fixture())
        after = (output["ttittulares/prepared.json"],
                 output["ttittulares/editorial-queue.json"],
                 output["telegram/editorial-processing.json"], {"items": []})
        self.assertIsNone(self.request(*after))

    def test_stale_revision_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "revision"):
            rework_ready_news(self.ID, 3, *self.fixture())

    def test_newer_editorial_queue_is_rejected(self):
        f = self.fixture()
        f[1]["items"].append({"event_id": self.ID, "revision": 5,
                              "status": "UPDATE_PROCESSING"})
        with self.assertRaisesRegex(ValueError, "mas reciente"):
            self.request(*f)

    def test_terminal_decision_is_rejected(self):
        f = self.fixture()
        f[3]["items"].append({"event_id": self.ID, "status": "published"})
        with self.assertRaisesRegex(ValueError, "terminal"):
            self.request(*f)

    def test_already_processing_same_revision_is_rejected(self):
        f = self.fixture()
        f[1]["items"][0]["status"] = "PROCESSING"
        with self.assertRaisesRegex(ValueError, "sigue en elaboracion"):
            self.request(*f)

    def test_nonunique_or_missing_ready_is_rejected(self):
        f = self.fixture()
        f[0]["items"].append(dict(f[0]["items"][0]))
        with self.assertRaisesRegex(ValueError, "una unica"):
            self.request(*f)
        f = self.fixture()
        f[0]["items"] = [f[0]["items"][1]]
        with self.assertRaisesRegex(ValueError, "una unica"):
            self.request(*f)


if __name__ == "__main__":
    unittest.main()
