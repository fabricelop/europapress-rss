#!/usr/bin/env python3
"""Pure local checks for the TTiTTulares V2 contract examples; no network or side effects."""
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent
BUNDLE = json.loads((ROOT / "examples" / "sample-bundle.json").read_text(encoding="utf-8"))
EVENT_ID = "ttn2-0123456789abcdef01234567"
EVENT_RE = re.compile(r"^ttn2-[a-f0-9]{24}$")
SHA_RE = re.compile(r"^[a-f0-9]{64}$")


class ContractExamples(unittest.TestCase):
    def test_event_identity_and_revision(self):
        event = BUNDLE["news_event"]
        self.assertTrue(EVENT_RE.fullmatch(event["event_id"]))
        self.assertEqual(event["current_revision"], 1)
        self.assertEqual(event["revision_refs"][0]["revision"], 1)

    def test_editorial_job_is_separate_from_event(self):
        event, job = BUNDLE["news_event"], BUNDLE["editorial_job"]
        self.assertEqual(job["event_id"], event["event_id"])
        self.assertEqual(job["revision"], event["current_revision"])
        self.assertEqual(job["status"], "pending")
        self.assertIsNone(job["lease"])
        self.assertIsNone(job["send_intent"])

    def test_ready_record_tweet_and_evidence(self):
        record = BUNDLE["editorial_record"]
        tweet = record["tweet"]
        self.assertEqual(record["record_status"], "ready")
        self.assertLessEqual(len(tweet["text"]), 256)
        self.assertEqual(tweet["character_count"], len(tweet["text"]))
        self.assertEqual(len(tweet["hashtags"]), 2)
        self.assertEqual(len({s["source_family"] for s in record["source_evidence"]}), 4)
        self.assertTrue(record["verification"]["essential_fact_verified"])
        self.assertTrue(SHA_RE.fullmatch(record["editorial_sha256"]))

    def test_image_uses_exact_editorial_revision(self):
        record, job, asset = (BUNDLE["editorial_record"], BUNDLE["image_job"], BUNDLE["image_asset"])
        self.assertEqual(job["event_id"], record["event_id"])
        self.assertEqual(job["revision"], record["revision"])
        self.assertEqual(job["editorial_sha256"], record["editorial_sha256"])
        self.assertEqual(asset["event_id"], record["event_id"])
        self.assertEqual(asset["revision"], record["revision"])
        self.assertEqual(asset["editorial_sha256"], record["editorial_sha256"])
        self.assertGreaterEqual(asset["width"], 1024)
        self.assertGreaterEqual(asset["height"], 576)

    def test_decision_is_explicit_and_revision_bound(self):
        decision = BUNDLE["decision_event"]
        self.assertEqual(decision["event_id"], EVENT_ID)
        self.assertEqual(decision["revision"], 1)
        self.assertEqual(decision["action"], "request_rework")
        self.assertIn("rework", decision)

    def test_publication_request_is_not_confirmation(self):
        receipt = BUNDLE["publication_receipt"]
        self.assertEqual(receipt["status"], "requested")
        self.assertIsNone(receipt["external_post_id"])
        self.assertIsNone(receipt["confirmed_at"])

    def test_queue_is_only_a_projection(self):
        queue, job = BUNDLE["queue_index"], BUNDLE["editorial_job"]
        self.assertEqual(queue["source_of_truth"], "individual_job_files")
        self.assertEqual(queue["pending_count"], len(queue["items"]))
        self.assertEqual(queue["items"][0]["job_id"], job["job_id"])

    def test_examples_do_not_leak_session_or_auth_material(self):
        raw = json.dumps(BUNDLE, ensure_ascii=False).lower()
        self.assertNotIn("bearer ", raw)
        self.assertNotIn("cookie", raw)
        self.assertNotIn("https://chatgpt.com/c/", raw)


if __name__ == "__main__":
    unittest.main(verbosity=2)
