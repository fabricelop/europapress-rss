"""Exact current-request retirement and opt-in permanent suppression regressions."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    import suppression as suppression_module
    import suppress_pending_term as retire_module
except ImportError:
    from trends import suppression as suppression_module
    from trends import suppress_pending_term as retire_module

key = suppression_module.key
is_suppressed = suppression_module.is_suppressed
purge_pending = suppression_module.purge_pending
clean_documents = retire_module.clean_documents


class SuppressionTests(unittest.TestCase):
    def test_released_labels_are_not_permanently_banned(self):
        self.assertEqual(key(" ESPAÑAS "), "espanas")
        for value in ("españas", "#DesterrarLaMonarquia", "#EncuestasManipuladas",
                      "España", "La España"):
            self.assertFalse(is_suppressed(value), value)
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "rules.json"
            config.write_text(json.dumps({"terms": [
                {"key": "espanas", "do_not_requeue": False},
                {"key": "explicit_permanent", "do_not_requeue": True},
            ]}), encoding="utf-8")
            with patch.object(suppression_module, "CONFIG", config):
                self.assertFalse(is_suppressed("españas"))
                self.assertTrue(is_suppressed("explicit_permanent"))
                self.assertFalse(is_suppressed("explicit_permanently"))

    def test_explicit_permanent_rule_is_scoped_to_exact_term(self):
        keys = {"desterrarlamonarquia"}
        for value in ("#DesterrarLaMonarquia", "DESTERRAR LA MONARQUÍA",
                      " #desterrarLaMonarquia "):
            self.assertTrue(is_suppressed(value, keys), value)
        for value in ("Monarquía", "#DesterrarLaMonarquiaYa", "#DesterrarLosInsultos"):
            self.assertFalse(is_suppressed(value, keys), value)

        requests = [
            {"id": "a", "name": "#DesterrarLaMonarquia",
             "status": "problematic", "reexplain": True, "with_image": True},
            {"id": "b", "name": "Zelda", "status": "preparing"},
            {"id": "c", "name": "Desterrar la Monarquía",
             "status": "update", "revision": 5},
            {"id": "d", "name": "Desterrar la Monarquía",
             "status": "published", "revision": 0},
        ]
        self.assertEqual(purge_pending(requests, keys=keys), 2)
        self.assertEqual(requests[0]["status"], "removed")
        self.assertFalse(requests[0]["with_image"])
        self.assertEqual(requests[1]["status"], "preparing")
        self.assertEqual(requests[2]["revision"], 5)
        self.assertEqual(requests[3]["status"], "published")
        self.assertEqual(purge_pending(requests, keys=keys), 0)

    def test_one_shot_retirement_preserves_radar_and_future_reentry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "suppressed-terms.json"
            config.write_text(json.dumps({
                "terms": [],
                "one_shot_retirements": [
                    {"id": "espanas-legacy", "revision": 3, "name": "españas"}
                ],
            }), encoding="utf-8")
            rows = [
                {"id": "espanas-legacy", "revision": 2, "name": "españas",
                 "status": "published"},
                {"id": "espanas-legacy", "revision": 3, "name": "españas",
                 "status": "problematic", "with_image": True},
                {"id": "espanas-future", "revision": 0, "name": "españas",
                 "status": "preparing"},
                {"id": "other", "revision": 3, "name": "La España",
                 "status": "problematic"},
            ]
            docs = {
                "requests.json": {"requests": rows},
                "editorial-queue.json": {"items": [rows[1], rows[2], rows[3]], "count": 3},
                "recent.json": {
                    "top10": ["españas", "La España"],
                    "top30": ["españas", "La España"],
                    "items": [{"name": "españas", "rank": 1},
                              {"name": "La España", "rank": 2}],
                    "sources": {"getdaytrends": {"trends": ["españas", "La España"]}},
                },
                "site-top30-current.json": {"items": [
                    {"name": "españas", "rank": 1, "card_id": "rank-1"},
                    {"name": "La España", "rank": 2, "card_id": "rank-2"}], "count": 2},
            }
            for filename, obj in docs.items():
                (root / filename).write_text(json.dumps(obj), encoding="utf-8")
            with patch.object(suppression_module, "CONFIG", config), patch.object(
                    retire_module, "CONFIG", config):
                changed = clean_documents(root)
                self.assertEqual(changed["one_shot_requests_retired"], 1)
                requests = json.loads((root / "requests.json").read_text(encoding="utf-8"))
                self.assertEqual(requests["requests"][0]["status"], "published")
                self.assertEqual(requests["requests"][1]["status"], "inactive")
                self.assertEqual(requests["requests"][1]["inactive_reason"],
                                 "editor_retired_current_occurrence")
                self.assertEqual(requests["requests"][2]["status"], "preparing")
                self.assertEqual(requests["requests"][3]["status"], "problematic")
                queue = json.loads((root / "editorial-queue.json").read_text(encoding="utf-8"))
                self.assertEqual([row["id"] for row in queue["items"]],
                                 ["espanas-future", "other"])
                recent = json.loads((root / "recent.json").read_text(encoding="utf-8"))
                self.assertEqual(recent["top30"], ["españas", "La España"])
                site = json.loads((root / "site-top30-current.json").read_text(encoding="utf-8"))
                self.assertEqual(site["count"], 2)
                self.assertEqual(clean_documents(root)["one_shot_requests_retired"], 0)

    def test_explicit_permanent_cleanup_does_not_delete_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "suppressed-terms.json"
            config.write_text(json.dumps({
                "terms": [{"key": "explicit_permanent", "do_not_requeue": True}],
                "one_shot_retirements": [],
            }), encoding="utf-8")
            rows = [{"id": "a", "name": "explicit_permanent", "status": "problematic"},
                    {"id": "b", "name": "Koldo", "status": "preparing"}]
            docs = {
                "requests.json": {"requests": rows},
                "editorial-queue.json": {"items": rows, "count": 2},
                "recent.json": {"top10": ["explicit_permanent", "Koldo"],
                                "top30": ["explicit_permanent", "Koldo"],
                                "items": [{"name": "explicit_permanent", "rank": 1},
                                          {"name": "Koldo", "rank": 2}],
                                "sources": {"a": {"trends": ["explicit_permanent", "Koldo"]}}},
                "site-top30-current.json": {"items": [
                    {"name": "explicit_permanent", "rank": 1, "card_id": "rank-1"},
                    {"name": "Koldo", "rank": 2, "card_id": "rank-2"}], "count": 2},
            }
            for filename, obj in docs.items():
                (root / filename).write_text(json.dumps(obj), encoding="utf-8")
            with patch.object(suppression_module, "CONFIG", config), patch.object(
                    retire_module, "CONFIG", config):
                changed = clean_documents(root)
                self.assertEqual(changed["requests_terminated"], 1)
                recent = json.loads((root / "recent.json").read_text(encoding="utf-8"))
                self.assertEqual(recent["top30"], ["Koldo"])
                self.assertEqual(recent["items"][0]["rank"], 1)
                requests = json.loads((root / "requests.json").read_text(encoding="utf-8"))
                self.assertEqual(requests["requests"][0]["status"], "removed")
                self.assertEqual(requests["requests"][1]["status"], "preparing")
                self.assertEqual(clean_documents(root)["requests_terminated"], 0)


if __name__ == "__main__":
    unittest.main()
