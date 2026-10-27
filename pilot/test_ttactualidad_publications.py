"""Synthetic tests only: never read or change production editorial JSON."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import importlib.util

spec = importlib.util.spec_from_file_location(
    "tt_direct", Path(__file__).with_name("apply-ttactualidad-action.py"))
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)


class PublishedConfirmation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.original_root = engine.ROOT
        engine.ROOT = self.root
        self.addCleanup(setattr, engine, "ROOT", self.original_root)
        self.event_id = "testunit1234"
        self.path_receipts = engine.LEDGER
        self.path_publications = engine.PUBLICATIONS
        self.write(self.path_receipts, {"version": 1, "items": []})
        self.write(self.path_publications, {"version": 1, "items": []})

    def write(self, path, data):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def read(self, path):
        return json.loads((self.root / path).read_text(encoding="utf-8"))

    def news(self):
        self.write("ttittulares/prepared.json", {
            "items": [{"event_id": self.event_id, "revision": 1,
                       "title": "Una noticia", "status": "READY"}], "count": 1})
        self.write("ttittulares/editorial-queue.json", {"items": []})
        self.write("ttittulares/decisions.json", {"items": []})

    def trends(self):
        self.write("trends/telegram-manual-explained.json", {
            "items": [{"id": self.event_id, "revision": 0, "status": "explained",
                       "name": "Tema", "explanation": "Texto confirmado",
                       "telegram_package_status": "ready"}]})
        self.write("trends/requests.json", {
            "requests": [{"id": self.event_id, "revision": 0,
                          "status": "explained", "name": "Tema",
                          "explanation": "Texto"}]})
        self.write("trends/telegram-image-deliveries.json", {"items": []})
        self.write("trends/mobile-decisions.json", {"items": []})

    def run_action(self, project, decision, revision, request_id="test-request-a1"):
        payload = json.dumps({"project": project, "event_id": self.event_id,
                              "decision": decision, "revision": revision,
                              "request_id": request_id, "trend_name": "Tema"})
        with patch.dict(os.environ, {"TT_ACTUALIDAD_EVENT_JSON": payload}):
            engine.main()

    def test_news_published_counts_once(self):
        self.news()
        self.run_action("ttittulares", "published", 1)
        self.assertEqual(self.read("ttittulares/prepared.json")["items"], [])
        self.assertEqual(self.read("ttittulares/decisions.json")["items"][0]["status"],
                         "published")
        p = self.read(self.path_publications)["items"]
        self.assertEqual(len(p), 1)
        self.assertEqual((p[0]["project"], p[0]["event_id"], p[0]["revision"]),
                         ("ttittulares", self.event_id, 1))
        self.assertTrue("+00:00" in p[0]["at"])
        self.run_action("ttittulares", "published", 1)
        self.run_action("ttittulares", "published", 1, "test-request-b2")
        self.assertEqual(len(self.read(self.path_publications)["items"]), 1)

    def test_news_not_published_removes_but_does_not_count(self):
        self.news()
        self.run_action("ttittulares", "deleted", 1)
        self.assertEqual(self.read("ttittulares/prepared.json")["items"], [])
        self.assertEqual(self.read("ttittulares/decisions.json")["items"][0]["status"],
                         "deleted")
        self.assertEqual(len(self.read(self.path_publications)["items"]), 0)

    def test_trend_published_counts_once_and_closes_mirrors(self):
        self.trends()
        self.run_action("ttendencias", "published", 0)
        self.assertEqual(self.read("trends/mobile-decisions.json")["items"][0]["status"],
                         "published")
        self.assertEqual(self.read("trends/requests.json")["requests"][0]["status"],
                         "published")
        self.assertEqual(self.read("trends/telegram-manual-explained.json")
                         ["items"][0]["status"], "published")
        self.assertEqual(len(self.read(self.path_publications)["items"]), 1)
        self.run_action("ttendencias", "published", 0, "test-request-b2")
        self.assertEqual(len(self.read(self.path_publications)["items"]), 1)

    def test_trend_not_published_closes_without_count(self):
        self.trends()
        self.run_action("ttendencias", "deleted", 0)
        self.assertEqual(self.read("trends/mobile-decisions.json")["items"][0]["status"],
                         "deleted")
        self.assertEqual(self.read(self.path_publications)["items"], [])

    def test_conflicting_reclassification_is_refused(self):
        self.news()
        self.run_action("ttittulares", "deleted", 1)
        with self.assertRaises(engine.InvalidAction):
            self.run_action("ttittulares", "published", 1, "test-request-b2")
        self.assertEqual(self.read(self.path_publications)["items"], [])


if __name__ == "__main__":
    unittest.main()
