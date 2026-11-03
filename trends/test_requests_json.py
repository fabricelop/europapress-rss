#!/usr/bin/env python3
"""Regression tests for all writers that can recreate an image-approval 503."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

from trends.requests_json import dumps_for_path


ROOT = Path(__file__).resolve().parent


class RequestsJsonTests(unittest.TestCase):
    def test_requests_roundtrip_with_identity_unicode_and_order(self):
        document = {
            "project": "TTendencias",
            "requests": [
                {
                    "id": "la-palma",
                    "revision": 3,
                    "episodeFingerprint": "a" * 64,
                    "commandId": "cmd-3",
                    "explanation": "Café, niña y 🌶️",
                    "details": {"line": "uno\ndos", "active": False},
                },
                {"id": "noticia-dos", "revision": 0, "notes": [1, None, True]},
            ],
            "count": 2,
        }
        compact = dumps_for_path(ROOT / "requests.json", document)
        self.assertEqual(json.loads(compact), document)
        self.assertEqual(compact.count("\n"), 1)
        self.assertTrue(compact.endswith("\n"))
        self.assertIn("🌶️", compact)
        self.assertLess(len(compact.encode("utf-16-le")) // 2,
                        len(json.dumps(document, ensure_ascii=False, indent=2).encode("utf-16-le")) // 2)
        self.assertEqual(list(json.loads(compact).keys()), list(document.keys()))
        self.assertEqual([r["id"] for r in json.loads(compact)["requests"]], ["la-palma", "noticia-dos"])

    def test_other_editorial_files_keep_their_format(self):
        data = {"requests": [{"id": "one"}]}
        pretty = dumps_for_path("editorial-queue.json", data)
        self.assertIn("\n  \"requests\": [", pretty)
        self.assertEqual(pretty, json.dumps(data, ensure_ascii=False, indent=2) + "\n")

    def test_reject_invalid_request_document_or_nan(self):
        for invalid in (None, {"requests": {}}, {"requests": [float("nan")]}):
            with self.subTest(invalid=str(invalid)):
                with self.assertRaises((ValueError, TypeError)):
                    dumps_for_path("requests.json", invalid)

    def test_every_live_writer_uses_compact_serializer(self):
        writers = {
            "auto_queue_new.py": "dumps_for_path(name, obj)",
            "apply_editorial_outbox.py": "dumps_for_path(path, obj)",
            "editorial_api.py": "dumps_for_path(path, data)",
            "apply_direct_reconcile.py": "dumps_for_path(path, obj)",
            "merge_runtime_state.py": 'dumps_for_path(root / "requests.json", merged_requests)',
            "../pilot/listas_grouping.py": "dumps_for_path(path, doc)",
        }
        for filename, expected in writers.items():
            with self.subTest(filename=filename):
                source = (ROOT / filename).read_text(encoding="utf-8")
                self.assertIn(expected, source)


if __name__ == "__main__":
    unittest.main()
