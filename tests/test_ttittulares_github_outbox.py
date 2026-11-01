#!/usr/bin/env python3
"""GitHub outbox: preserve exact news/revision/sha before associating an image."""
import base64
import hashlib
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ttittulares"))
import apply_ai_image_outbox as job


class DirectReceiptTests(unittest.TestCase):
    def setUp(self):
        self.txt = "Hechos y remate\nSin inventar"
        self.facts = "Un hecho verificado"
        self.remate = "Final"
        self.fingerprint = hashlib.sha256(
            "\n".join((self.txt, self.facts, self.remate)).encode("utf-8")
        ).hexdigest()
        self.row = {
            "event_id": "newsABC", "revision": 2,
            "tweet": {"text": self.txt, "remate": self.remate},
            "factual_summary": self.facts,
        }
        self.payload = {
            "event_id": "newsABC", "revision": 2,
            "command_id": "tt-img-abc-r2", "editorial_sha256": self.fingerprint,
            "ai_image": {
                "chunk_files": ["tt-img-abc-r2.b64"],
                "chunk_mime": "image/png",
                "context_guard": {
                    "command_id": "tt-img-abc-r2",
                    "event_id": "newsABC",
                    "revision": 2,
                    "editorial_sha256": self.fingerprint,
                },
            },
        }

    def test_exact_receipt_only(self):
        self.assertTrue(job._direct_receipt_matches(self.payload, self.row))
        for diff in (
            {"event_id": "newsDifferent"},
            {"revision": 3},
            {"editorial_sha256": "0" * 64},
            {"command_id": "other-command"},
        ):
            variant = {**self.payload, **diff}
            self.assertFalse(job._direct_receipt_matches(variant, self.row))
        row = {**self.row, "tweet": {"text": "Edición nueva", "remate": self.remate}}
        self.assertFalse(job._direct_receipt_matches(self.payload, row))

    def test_chunk_hash_integrity(self):
        data = b"real-original-bytes" * 1000
        with tempfile.TemporaryDirectory() as temp:
            old = job.OUTBOX
            job.OUTBOX = pathlib.Path(temp)
            try:
                name = "tt-img-abc-r2.b64"
                (job.OUTBOX / name).write_text(base64.b64encode(data).decode())
                payload = {
                    "ai_image": {
                        "chunk_files": [name],
                        "chunk_mime": "image/png",
                        "chunk_sha256": hashlib.sha256(data).hexdigest(),
                    }
                }
                files = job._hydrate_chunked_ai(payload)
                self.assertEqual(len(files), 1)
                self.assertTrue(payload["ai_image"]["url"].startswith("data:image/png;base64,"))
                payload["ai_image"]["chunk_sha256"] = "0" * 64
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    job._hydrate_chunked_ai(payload)
            finally:
                job.OUTBOX = old


if __name__ == "__main__":
    unittest.main()
