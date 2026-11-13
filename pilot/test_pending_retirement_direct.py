"""Exercise the authenticated Cloudflare/GitHub action on exact pending revision."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("apply-ttactualidad-action.py")
spec = importlib.util.spec_from_file_location("tt_actions_pending_test", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class PendingDirectTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.previous_root = mod.ROOT
        mod.ROOT = Path(self.tmp.name)
        self.addCleanup(lambda: setattr(mod, "ROOT", self.previous_root))
        def write(name, obj):
            path = mod.ROOT / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(obj), encoding="utf-8")
        self.write = write
        self.write("trends/requests.json", {"requests": [
            {"id": "1ea1a6c850b1", "name": "españas", "status": "problematic",
             "revision": 3},
            {"id": "other", "name": "Colau", "status": "preparing", "revision": 1}
        ]})
        self.write("trends/editorial-queue.json", {"items": [
            {"id": "1ea1a6c850b1", "name": "españas",
             "status": "problematic", "revision": 3},
            {"id": "other", "name": "Colau", "status": "preparing", "revision": 1}
        ], "count": 2})
        self.write("trends/recent.json", {"items": [
            {"name": "españas", "rank": 13,
             "entered_top30_at": "2026-11-13T20:00:00+01:00"}]})
        self.write("trends/pending-retirements.json", {"items": []})

    def test_direct_retire_is_neither_publication_nor_permanent_blacklist(self):
        changes, result = mod.apply_live(
            "ttendencias", "1ea1a6c850b1", "retire", 3, "españas", 13)
        self.assertEqual(result, "applied")
        self.assertEqual(changes["trends/requests.json"]["requests"][0]["status"], "inactive")
        self.assertEqual(changes["trends/editorial-queue.json"]["count"], 1)
        record = changes["trends/pending-retirements.json"]["items"][0]
        self.assertEqual((record["name"], record["revision"]), ("españas", 3))
        self.assertNotIn("trends/mobile-decisions.json", changes)
        self.assertEqual(changes["trends/recent.json"]["items"][0]["name"], "españas") if "trends/recent.json" in changes else None

    def test_direct_stale_revision_is_rejected(self):
        with self.assertRaises(mod.InvalidAction):
            mod.apply_live("ttendencias", "1ea1a6c850b1", "retire", 2, "españas", 13)


if __name__ == "__main__":
    unittest.main()
