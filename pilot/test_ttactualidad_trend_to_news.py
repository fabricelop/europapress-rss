"""Synthetic-only tests for TTendencias-to-TTiTTulares manual handoff."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "manual", Path(__file__).parent / "submit_ttactualidad_manual.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class TrendToNewsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.before = mod.ROOT
        mod.ROOT = Path(self.tmp.name)
        self.addCleanup(lambda: setattr(mod, "ROOT", self.before))
        self.save(mod.PROCESSING, {"items": []})
        self.save(mod.COMPACT, {"items": [], "count": 0})
        self.save(mod.PREPARED, {"items": []})
        self.save("trends/requests.json", {"requests": [
            {"id": "3ddbfd7e26b4", "name": "#FreeParacetamol",
             "revision": 0, "status": "inactive"}
        ]})
        self.save("trends/recent.json", {"items": []})

    def save(self, path, data):
        dest = mod.ROOT / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(data), encoding="utf-8")

    def request(self):
        return {
            "project": "ttittulares",
            "request_id": "3a7d54c8-9e3a-4d92-8ee4-298fcc4125d3",
            "title": "Investigar noticia detrás de #FreeParacetamol",
            "url": "",
            "instructions": "Origen en TTendencias; investigar fuentes independientes antes de publicar.",
            "origin_trend": {
                "id": "3ddbfd7e26b4", "revision": 0, "name": "#FreeParacetamol"
            }
        }

    def test_handoff_persists_only_in_existing_news_queue(self):
        outcome, eid = mod.apply(self.request(), at="2026-10-27T17:00:00Z")
        self.assertEqual(outcome, "added")
        self.assertTrue(eid.startswith("manual-"))
        queue = mod.read(mod.COMPACT)["items"][0]
        full = mod.read(mod.PROCESSING)["items"][0]
        for item in (queue, full):
            self.assertEqual(item["origin_project"], "ttendencias")
            self.assertEqual(item["origin_trend_id"], "3ddbfd7e26b4")
            self.assertEqual(item["origin_trend_revision"], 0)
            self.assertEqual(item["status"], "PROCESSING")
        self.assertEqual(full["verified_source_count"], 0)
        self.assertEqual(mod.read(mod.COMPACT)["count"], 1)
        self.assertEqual(json.loads((mod.ROOT / "trends/requests.json").read_text())["requests"][0]["status"], "inactive")

    def test_retry_same_request_id_does_not_duplicate(self):
        self.assertEqual(mod.apply(self.request())[0], "added")
        self.assertEqual(mod.apply(self.request())[0], "already_received")
        self.assertEqual(len(mod.read(mod.COMPACT)["items"]), 1)

    def test_old_revision_and_forged_id_rejected(self):
        payload = self.request()
        for origin in [
            {"id": "3ddbfd7e26b4", "revision": 1, "name": "#FreeParacetamol"},
            {"id": "invented-123", "revision": 0, "name": "#FreeParacetamol"},
        ]:
            payload["origin_trend"] = origin
            with self.assertRaises(ValueError):
                mod.apply(payload)
        self.assertFalse(mod.read(mod.PROCESSING)["items"])

    def test_legacy_manual_without_origin_still_works(self):
        payload = self.request()
        payload.pop("origin_trend")
        self.assertEqual(mod.apply(payload)[0], "added")
        self.assertNotIn("origin_trend_id", mod.read(mod.COMPACT)["items"][0])

if __name__ == "__main__":
    unittest.main()
