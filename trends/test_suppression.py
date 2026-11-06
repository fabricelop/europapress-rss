"""Exact, user-authorized suppression without touching unrelated topics."""
import json
import tempfile
import unittest
from pathlib import Path

try:
    from suppression import key, is_suppressed, purge_pending
    from suppress_pending_term import clean_documents
except ImportError:
    from trends.suppression import key, is_suppressed, purge_pending
    from trends.suppress_pending_term import clean_documents


class SuppressionTests(unittest.TestCase):
    def test_only_exact_hashtag_variants_are_removed(self):
        for v in ("#DesterrarLaMonarquia", "DESTERRAR LA MONARQUÍA",
                  " #desterrarLaMonarquia "):
            self.assertTrue(is_suppressed(v), v)
        for v in ("Monarquía", "#DesterrarLaMonarquiaYa", "#DesterrarLosInsultos"):
            self.assertFalse(is_suppressed(v), v)

    def test_pending_statuses_terminal_and_other_trends_untouched(self):
        requests = [
            {"id": "a", "name": "#DesterrarLaMonarquia",
             "status": "problematic", "reexplain": True, "with_image": True},
            {"id": "b", "name": "Zelda", "status": "preparing"},
            {"id": "c", "name": "Desterrar la Monarquía",
             "status": "update", "revision": 5},
            {"id": "d", "name": "Desterrar la Monarquía",
             "status": "published", "revision": 0},
        ]
        self.assertEqual(purge_pending(requests), 2)
        self.assertEqual(requests[0]["status"], "removed")
        self.assertFalse(requests[0]["with_image"])
        self.assertEqual(requests[1]["status"], "preparing")
        self.assertEqual(requests[2]["revision"], 5)
        self.assertEqual(requests[3]["status"], "published")
        self.assertEqual(purge_pending(requests), 0)

    def test_clean_visible_sources_and_preserve_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rows = [{"id": "a", "name": "#DesterrarLaMonarquia", "status": "problematic"},
                    {"id": "b", "name": "Koldo", "status": "preparing"}]
            docs = {
                "requests.json": {"requests": rows},
                "editorial-queue.json": {"items": rows, "count": 2},
                "recent.json": {
                    "top10": ["#DesterrarLaMonarquia", "Koldo"],
                    "top30": ["#DesterrarLaMonarquia", "Koldo"],
                    "items": [{"name": "#DesterrarLaMonarquia", "rank": 1},
                              {"name": "Koldo", "rank": 2}],
                    "upcoming": [{"name": "#DesterrarLaMonarquia"}],
                    "sources": {"a": {"trends": ["#DesterrarLaMonarquia", "Koldo"]}},
                },
                "site-top30-current.json": {"items": [
                    {"name": "#DesterrarLaMonarquia", "rank": 1, "card_id": "rank-1"},
                    {"name": "Koldo", "rank": 2, "card_id": "rank-2"}], "count": 2}
            }
            for filename, data in docs.items():
                (root / filename).write_text(json.dumps(data), encoding="utf-8")
            result = clean_documents(root)
            self.assertEqual(result["requests_terminated"], 1)
            self.assertEqual(result["queued_removed"], 1)
            final = json.loads((root / "recent.json").read_text(encoding="utf-8"))
            self.assertEqual(final["top30"], ["Koldo"])
            self.assertEqual(final["items"][0]["rank"], 1)
            self.assertEqual(final["sources"]["a"]["trends"], ["Koldo"])
            requests = json.loads((root / "requests.json").read_text(encoding="utf-8"))
            self.assertEqual(requests["requests"][0]["status"], "removed")
            self.assertEqual(requests["requests"][1]["status"], "preparing")
            site = json.loads((root / "site-top30-current.json").read_text(encoding="utf-8"))
            self.assertEqual(site["items"][0]["name"], "Koldo")
            self.assertEqual(site["items"][0]["card_id"], "rank-1")
            self.assertEqual(clean_documents(root)["requests_terminated"], 0)


if __name__ == "__main__":
    unittest.main()
