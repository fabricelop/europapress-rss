#!/usr/bin/env python3
"""Contrato público del Top30 V2, sin red ni efectos."""
import base64
import hashlib
import io
import json
import unittest
from datetime import datetime, timezone
from unittest.mock import patch
from v2.ttendencias.web_top30_v2 import build, read_remote
from v2.ttendencias.consume_re_requests import github_read


def encoded_sha(payload):
    return hashlib.sha1(b"blob " + str(len(payload)).encode("ascii")
                        + b"\x00" + payload).hexdigest()


def fixtures():
    names = ["Trend%02d" % n for n in range(1, 31)]
    topics = {}
    items = {}
    for i, name in enumerate(names, 1):
        ident = "trv2-id-%02d" % i
        topics[name] = {"name": name, "trend_id": ident, "active": True,
                        "rank": i, "last_change": "unchanged"}
        items[ident] = {"name": name, "trend_id": ident, "status": "pending",
                        "revision": 1, "secret": "DO_NOT_LEAK"}
    h = {"step": "03_movement", "country": "ES",
         "observed_at": "2026-11-13T17:45:00+00:00",
         "source": "GetDayTrends", "top30": names, "topics": topics}
    q = {"step": "04_editorial_queue", "effects_enabled": False,
         "source_observed_at": h["observed_at"], "items": items}
    return h, q


class Top30WebTests(unittest.TestCase):
    def test_oversized_queue_reads_immutable_blob(self):
        state = {"step": "04_editorial_queue", "items": {"Sanchez":
                 {"status": "captured_review", "capture": {"verified_complete": True}}}}
        payload = json.dumps(state).encode("utf-8")
        sha = encoded_sha(payload)
        metadata = {"encoding": "none", "content": "", "sha": sha}
        blob = {"encoding": "base64", "content": base64.b64encode(payload).decode()}
        with patch("v2.ttendencias.web_top30_v2.gh", return_value=metadata):
            with patch("v2.ttendencias.web_top30_v2.urllib.request.urlopen",
                       return_value=io.BytesIO(json.dumps(blob).encode())) as opened:
                recovered, recovered_sha = read_remote("test-token", "editorial-queue.json")
        self.assertEqual(recovered, state)
        self.assertEqual(recovered_sha, sha)
        self.assertEqual(opened.call_args[0][0].full_url,
                         "https://api.github.com/repos/fabricelop/europapress-rss/git/blobs/" + sha)

    def test_oversized_queue_rejects_blob_sha_mismatch(self):
        payload = b'{"items": {}}'
        metadata = {"encoding": "none", "content": "", "sha": "a" * 40}
        blob = {"encoding": "base64", "content": base64.b64encode(payload).decode()}
        with patch("v2.ttendencias.web_top30_v2.gh", return_value=metadata):
            with patch("v2.ttendencias.web_top30_v2.urllib.request.urlopen",
                       return_value=io.BytesIO(json.dumps(blob).encode())):
                with self.assertRaisesRegex(RuntimeError, "SHA mismatch"):
                    read_remote("test-token", "editorial-queue.json")

    def test_standard_base64_content_still_works(self):
        state = {"items": {"Sanchez": {"status": "captured_review"}}}
        payload = json.dumps(state).encode()
        metadata = {"encoding": "base64",
                    "content": base64.b64encode(payload).decode(),
                    "sha": encoded_sha(payload)}
        with patch("v2.ttendencias.web_top30_v2.gh", return_value=metadata):
            result, sha = read_remote("test-token", "editorial-queue.json")
        self.assertEqual(result, state)
        self.assertEqual(sha, metadata["sha"])

    def test_github_actions_re_consumer_reads_oversized_editorial_queue(self):
        state = {"items": {"trv2-test": {"status": "in_progress"}}}
        raw = json.dumps(state).encode()
        meta = {"encoding": "none", "content": "", "sha": encoded_sha(raw)}
        blob = {"encoding": "base64", "content": base64.b64encode(raw).decode()}
        with patch("v2.ttendencias.consume_re_requests.request_json", return_value=meta):
            with patch("v2.ttendencias.web_top30_v2.urllib.request.urlopen",
                       return_value=io.BytesIO(json.dumps(blob).encode())):
                decoded, sha = github_read("test-token", "editorial-queue.json")
        self.assertEqual(decoded, state)
        self.assertEqual(sha, meta["sha"])

    def test_exact_order_and_count(self):
        h, q = fixtures()
        doc = build(h, q)
        self.assertEqual(doc["count"], 30)
        self.assertEqual([t["rank"] for t in doc["items"]], list(range(1,31)))
        self.assertEqual(doc["items"][0]["name"], "Trend01")
        self.assertIn("entered_top30_at", doc["items"][0])
        self.assertFalse(doc["publication_allowed"])

    def test_movement_details_reach_public_ranking(self):
        h, q = fixtures()
        h["previous_observed_at"] = "2026-11-13T17:30:00+00:00"
        h["ranking_unchanged"] = True
        h["ranking_change_at"] = "2026-11-13T17:30:00+00:00"
        h["topics"]["Trend01"].update(last_change="up", previous_rank=5, positions_changed=4)
        h["topics"]["Trend02"].update(last_change="down", previous_rank=1, positions_changed=-1)
        h["topics"]["Trend03"].update(last_change="unchanged", previous_rank=3, positions_changed=0)
        doc = build(h, q)
        self.assertEqual(doc["comparison_at"], h["previous_observed_at"])
        self.assertTrue(doc["ranking_unchanged"])
        self.assertEqual(doc["ranking_change_at"], h["ranking_change_at"])
        self.assertEqual([(i["previous_rank"], i["positions_changed"]) for i in doc["items"][:3]],
                         [(5, 4), (1, -1), (3, 0)])
        self.assertIsNone(doc["items"][3]["previous_rank"])

    def test_no_auth_or_lease_leak(self):
        h, q = fixtures()
        q["items"]["trv2-id-01"]["lease"]={"token": "secret-lease"}
        q["items"]["trv2-id-01"]["send_intent"]={"token": "secret-send"}
        doc = build(h, q)
        self.assertNotIn("secret", str(doc))
        self.assertNotIn("token", str(doc))

    def test_in_progress_shows_elaboration(self):
        h, q = fixtures()
        q["items"]["trv2-id-01"]["status"]="in_progress"
        doc = build(h, q)
        self.assertEqual(doc["items"][0]["status"], "en_elaboracion")

    def test_expired_lease_is_incident_without_reopening_chat(self):
        h,q=fixtures()
        q["items"]["trv2-id-01"]["status"]="in_progress"
        q["items"]["trv2-id-01"]["lease"]={"token":"NEVER_EXPOSE",
            "expires_at":"2026-01-01T00:00:00Z"}
        row=build(h,q)["items"][0]
        self.assertEqual(row["status"],"incidencia")
        self.assertEqual(row["status_label"],"Elaboración interrumpida")
        self.assertNotIn("NEVER_EXPOSE",str(row))

    def test_capture_verified_shows_text_and_cause(self):
        h, q = fixtures()
        row=q["items"]["trv2-id-01"]
        row["status"]="captured_review"
        row["capture"]={"revision":1, "verified_complete":True,
                        "answer":"Un texto editorial documentado " * 5
                                 +"\nESTADO_CAUSA: NO_CONFIRMADA",
                        "sha256":"f"*64,"chat_url":"https://chatgpt.com/c/valid-chat",
                        "captured_at":"2026-11-13T17:50:00+00:00"}
        doc=build(h, q); first=doc["items"][0]
        self.assertEqual(first["status"], "explicada")
        self.assertEqual(first["cause_status"], "no_confirmada")
        self.assertTrue(first["pending_editorial_review"])
        self.assertTrue(first["chat_url"].startswith("https://chatgpt.com/c/"))

    def test_incomplete_capture_is_incident_not_explained(self):
        h, q = fixtures()
        q["items"]["trv2-id-01"].update(status="captured_review",
                                          capture={"revision":1,"answer":"too short",
                                                   "verified_complete":False})
        doc=build(h,q)
        self.assertEqual(doc["items"][0]["status"],"incidencia")
        self.assertEqual(doc["items"][0]["explanation"],"")

    def test_image_indicator_requires_saved_original_of_same_revision(self):
        h, q = fixtures()
        ident = "trv2-" + "a" * 24
        q["items"][ident] = q["items"].pop("trv2-id-01")
        q["items"][ident]["trend_id"] = ident
        h["topics"]["Trend01"]["trend_id"] = ident
        item = q["items"][ident]
        item["status"] = "captured_review"
        sha = "c" * 64
        image = {"status": "saved", "revision": 1,
                 "backend": "github_v1_style", "sha256": sha, "mime": "image/png",
                 "command_id": "v2-img-" + ident + "-r1-a1-1234567890abcdef",
                 "path": "v2/ttendencias/generated-images/" + ident + "-r1-" + sha[:24] + ".png"}
        item["capture"] = {"revision": 1, "image": image}
        self.assertTrue(build(h, q)["items"][0]["image_available"])
        image["path"] = "v2/ttendencias/generated-images/" + ident + ".image"
        self.assertTrue(build(h, q)["items"][0]["image_available"])
        image["revision"] = 2
        self.assertFalse(build(h, q)["items"][0]["image_available"])
        image["revision"] = 1
        image["path"] = "v2/ttendencias/generated-images/wrong.png"
        self.assertFalse(build(h, q)["items"][0]["image_available"])

    def test_image_in_progress_requires_live_matching_revision(self):
        from datetime import timedelta
        h, q = fixtures()
        row = q["items"]["trv2-id-01"]
        row["status"] = "captured_review"
        row["capture"] = {"revision": 1, "verified_complete": True,
                          "answer": "Texto editorial verificado " * 5,
                          "sha256": "c" * 64}
        progress = {"status": "in_progress", "revision": 1,
                    "editorial_sha256": "c" * 64,
                    "command_id": "PRIVATE_IMAGE_JOB",
                    "expires_at": (datetime.now(timezone.utc)
                                   + timedelta(minutes=15)).isoformat()}
        row["image_progress"] = progress
        view = build(h, q)["items"][0]
        self.assertTrue(view["image_in_progress"])
        self.assertFalse(view["image_available"])
        self.assertNotIn("PRIVATE_IMAGE_JOB", str(view))
        progress["revision"] = 2
        self.assertFalse(build(h, q)["items"][0]["image_in_progress"])
        progress["revision"] = 1
        progress["editorial_sha256"] = "a" * 64
        self.assertFalse(build(h, q)["items"][0]["image_in_progress"])
        progress["editorial_sha256"] = "c" * 64
        progress["expires_at"] = "2020-01-01T00:00:00Z"
        self.assertFalse(build(h, q)["items"][0]["image_in_progress"])
        row["status"] = "in_progress"
        self.assertFalse(build(h, q)["items"][0]["image_in_progress"])

    def test_image_retry_counters_are_revision_bound_and_fail_closed(self):
        h, q = fixtures()
        item = q["items"]["trv2-id-01"]
        item.update(status="captured_review", capture={"revision": 1,
            "verified_complete": True, "answer": "Texto verificado " * 10,
            "sha256": "d" * 64})
        item["image_retry_summary"] = {"revision": 1, "editorial_sha256": "d" * 64,
            "state": "retry_pending", "send_attempts": 0, "send_limit": 3,
            "pre_send_failures": 2, "pre_send_limit": 3}
        row = build(h, q)["items"][0]
        self.assertEqual(row["image_retry"]["remaining"], 3)
        self.assertEqual(row["image_retry"]["pre_send_failures"], 2)
        item["image_retry_summary"]["state"] = "blocked"
        self.assertEqual(build(h, q)["items"][0]["image_retry"]["remaining"], 0)
        item["image_retry_summary"]["state"] = "exhausted"
        self.assertEqual(build(h, q)["items"][0]["image_retry"]["remaining"], 0)
        item["image_retry_summary"]["editorial_sha256"] = "e" * 64
        self.assertEqual(build(h, q)["items"][0]["image_retry"]["state"], "unknown")
        item["image_retry_summary"]["editorial_sha256"] = "d" * 64
        item["image_retry_summary"]["revision"] = 2
        self.assertEqual(build(h, q)["items"][0]["image_retry"]["state"], "unknown")

    def test_capture_recovery_shows_incident(self):
        h, q=fixtures()
        q["items"]["trv2-id-01"]["status"]="capture_recovery"
        self.assertEqual(build(h,q)["items"][0]["status"],"incidencia")

    def test_mismatch_refused(self):
        h, q=fixtures()
        q["source_observed_at"]="2026-11-13T17:44:00+00:00"
        with self.assertRaises(ValueError):
            build(h,q)

    def test_incomplete_top30_refused(self):
        h,q=fixtures()
        h["top30"].pop()
        with self.assertRaises(ValueError):
            build(h,q)

    def test_duplicate_ranks_refused(self):
        h,q=fixtures()
        h["topics"]["Trend02"]["rank"]=1
        with self.assertRaises(ValueError):
            build(h,q)

    def test_no_effects_enabled(self):
        h,q=fixtures()
        q["effects_enabled"]=True
        with self.assertRaises(ValueError):
            build(h,q)


if __name__ == "__main__":
    unittest.main()
