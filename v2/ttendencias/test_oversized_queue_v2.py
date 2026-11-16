#!/usr/bin/env python3
"""Regression: GitHub Contents API returns encoding=none for files over 1 MiB.

Run: python -m unittest v2/ttendencias/test_oversized_queue_v2.py
No GitHub writes, browser, token, or publication.
"""
import base64
import hashlib
import importlib.util
import io
import json
import pathlib
import sys
import types
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
SOURCE = (HERE / "editorial_run_v2.py").read_text(encoding="utf-8")
# Extract only queue_read, avoiding Playwright and browser imports.
import ast
tree = ast.parse(SOURCE)
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "queue_read")
code = compile(ast.Module(body=[fn], type_ignores=[]), str(HERE / "editorial_run_v2.py"), "exec")
scope = {"base64": base64, "hashlib": hashlib, "json": json}
exec(code, scope)
queue_read = scope["queue_read"]


def blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\x00" + data).hexdigest()


class FakeAPI:
    def __init__(self, meta):
        self.meta = meta

    def request(self, method, auth):
        assert method == "GET"
        return self.meta


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, *args):
        return self.payload


class QueueReadRegression(unittest.TestCase):
    def setUp(self):
        self.queue = {"step": "04_editorial_queue", "effects_enabled": False,
                      "items": {"x": {"answer": "a" * (1024 * 1024 + 128)}}}
        self.raw = json.dumps(self.queue).encode("utf-8")
        self.sha = blob_sha(self.raw)

    def test_oversized_encoding_none_uses_immutable_sha(self):
        meta = {"encoding": "none", "content": "", "sha": self.sha}
        blob = {"encoding": "base64", "content": base64.b64encode(self.raw).decode("ascii")}
        seen = []

        def urlopen(req, timeout):
            seen.append(req.full_url)
            return FakeResponse(json.dumps(blob).encode("utf-8"))

        with patch("urllib.request.urlopen", side_effect=urlopen):
            result, sha = queue_read(FakeAPI(meta), None)
        self.assertEqual(sha, self.sha)
        self.assertEqual(result, self.queue)
        self.assertEqual(seen, [
            "https://api.github.com/repos/fabricelop/europapress-rss/git/blobs/" + self.sha
        ])

    def test_oversized_wrong_sha_rejected(self):
        meta = {"encoding": "none", "content": "", "sha": "0" * 40}
        blob = {"encoding": "base64", "content": base64.b64encode(self.raw).decode("ascii")}
        with patch("urllib.request.urlopen", return_value=FakeResponse(json.dumps(blob).encode())):
            with self.assertRaisesRegex(RuntimeError, "SHA_MISMATCH"):
                queue_read(FakeAPI(meta), None)

    def test_normal_base64_still_works(self):
        meta = {"encoding": "base64",
                "content": base64.b64encode(self.raw).decode("ascii"), "sha": self.sha}
        result, sha = queue_read(FakeAPI(meta), None)
        self.assertEqual(sha, self.sha)
        self.assertEqual(result, self.queue)

    def test_missing_sha_does_not_download_branch(self):
        with patch("urllib.request.urlopen") as fetch:
            with self.assertRaisesRegex(RuntimeError, "SHA_MISSING"):
                queue_read(FakeAPI({"encoding": "none", "content": ""}), None)
            fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
