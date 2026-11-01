#!/usr/bin/env python3
"""Pure regression tests: prepared READY, real raster hash, stable ID, no overwrites."""
import hashlib
import tempfile
import unittest
from pathlib import Path
from ttittulares.sync_site_ai_images import from_ready, sync


class NewsImageCatalogTests(unittest.TestCase):
    def test_verified_png_adds_once_and_keeps_older_revisions(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            files = root / "ttittulares/generated-images"
            files.mkdir(parents=True)
            data = b"\x89PNG\r\n\x1a\n" + b"a" * 300
            path = files / "newsABC-r1-ai1.png"
            path.write_bytes(data)
            sha = hashlib.sha256(data).hexdigest()
            item = {
                "event_id": "newsABC", "revision": 1, "prepared_at": "2026-11-01T16:00:00Z",
                "tweet": {"text": "Factual exact"},
                "ai_image_status": "ready",
                "ai_image": {
                    "generated": True, "provider": "chat-imagegen",
                    "sha256": sha,
                    "url": "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
                           "ttittulares/generated-images/newsABC-r1-ai1.png",
                    "context_guard": {"event_id": "newsABC", "revision": 1},
                },
                "archive_image": {"url": "https://example.org/archived.jpg"},
            }
            prepared = {"items": [item]}
            manifest = {"schema_version": 1, "project": "ttittulares", "images": []}
            first, n = sync(prepared, manifest, root)
            self.assertEqual(n, 1)
            self.assertEqual(first["images"][0]["target_id"], "newsABC")
            self.assertEqual(first["images"][0]["sha256"], sha)
            self.assertEqual(item["archive_image"]["url"], "https://example.org/archived.jpg")
            second, n = sync(prepared, first, root)
            self.assertEqual(n, 0)
            self.assertEqual(second["images"], first["images"])
            item["revision"] = 2
            item["tweet"]["text"] = "New editorial version"
            # Original image remains linked to the stable news ID, not deleted.
            after_edit, n = sync(prepared, first, root)
            self.assertEqual(n, 0)
            self.assertEqual(len(after_edit["images"]), 1)

    def test_rejects_missing_bytes_bad_sha_and_cross_news_context(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "ttittulares/generated-images").mkdir(parents=True)
            item = {
                "event_id": "newsABC", "revision": 1,
                "prepared_at": "2026-11-01T16:00:00Z",
                "tweet": {"text": "Verified"},
                "ai_image_status": "ready",
                "ai_image": {
                    "generated": True, "provider": "chat-imagegen",
                    "sha256": "a" * 64,
                    "url": "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
                           "ttittulares/generated-images/newsABC-r1-ai1.png",
                    "context_guard": {"event_id": "otherNews", "revision": 1},
                },
            }
            self.assertIsNone(from_ready(item, root))
            item["ai_image"]["context_guard"]["event_id"] = "newsABC"
            self.assertIsNone(from_ready(item, root))
            (root / "ttittulares/generated-images/newsABC-r1-ai1.png").write_bytes(b"wrong")
            self.assertIsNone(from_ready(item, root))

    def test_preserve_existing_image_for_same_event_and_revision(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            manifest = {
                "schema_version": 1, "project": "ttittulares",
                "images": [{
                    "target_id": "newsABC", "revision": 1,
                    "prepared_at": "old", "editorial_text": "original",
                    "sha256": "a" * 64, "image_url": "https://site.example/original.png",
                }],
            }
            new, count = sync({"items": []}, manifest, root)
            self.assertEqual(count, 0)
            self.assertEqual(new["images"], manifest["images"])


if __name__ == "__main__":
    unittest.main()
