#!/usr/bin/env python3
import base64
import json
import os
import unittest
from unittest.mock import patch

from apply_editorial_outbox import parse_payload


class EditorialOutboxTransportTests(unittest.TestCase):
    def setUp(self):
        self.payload_v1 = {"version": 1, "run_id": "fixture-v1", "outputs": [{"request_key": "evaluate:test"}]}
        self.payload_v2 = {"version": 2, "run_id": "fixture-v2", "outputs": [{"request_key": "evaluate:test"}]}

    def parse(self, body):
        with patch.dict(os.environ, {"SELORECORDAMOS_COMMENT_BODY": body}):
            return parse_payload()

    def test_existing_v1_base64_remains_valid(self):
        encoded = base64.b64encode(json.dumps(self.payload_v1).encode("utf-8")).decode("ascii")
        self.assertEqual(self.parse("SELORECORDAMOS_OUTBOX_V1\n" + encoded), self.payload_v1)

    def test_v2_plain_json_valid(self):
        self.assertEqual(self.parse("SELORECORDAMOS_OUTBOX_V2\n" + json.dumps(self.payload_v2, ensure_ascii=False)), self.payload_v2)

    def test_v2_multiline_json_valid(self):
        body = "SELORECORDAMOS_OUTBOX_V2\n" + json.dumps(self.payload_v2, indent=2)
        self.assertEqual(self.parse(body), self.payload_v2)

    def test_v2_rejects_wrong_version(self):
        with self.assertRaisesRegex(ValueError, "Versión"):
            self.parse("SELORECORDAMOS_OUTBOX_V2\n" + json.dumps(self.payload_v1))

    def test_bad_or_empty_payload_fails(self):
        for body in ["SELORECORDAMOS_OUTBOX_V2\n", "SOME_OTHER_MARKER\n{}", "SELORECORDAMOS_OUTBOX_V2\nno es JSON"]:
            with self.subTest(body=body), self.assertRaises((ValueError, json.JSONDecodeError)):
                self.parse(body)

    def test_v2_rejects_empty_outputs(self):
        with self.assertRaisesRegex(ValueError, "outputs"):
            self.parse("SELORECORDAMOS_OUTBOX_V2\n" + json.dumps({"version": 2, "run_id": "fixture", "outputs": []}))


if __name__ == "__main__":
    unittest.main()
