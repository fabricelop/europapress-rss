import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / "ttactualidad_buffer_publish.py"
spec = importlib.util.spec_from_file_location("tt_buffer", MODULE)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)

URL = ("https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
       "ttittulares/generated-images/test-r1.png")
HASH = "a" * 64


class DirectBufferPublisherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.patch = mock.patch.object(publisher, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        p = mock.patch.object(publisher, "LEDGER",
                              self.root / "pilot/ttactualidad-buffer-posts.json")
        p.start()
        self.addCleanup(p.stop)
        self.saved = []
        m = mock.patch.object(publisher, "save",
                              side_effect=lambda data, reason: self.saved.append(reason))
        m.start()
        self.addCleanup(m.stop)
        self._write("ttittulares/prepared.json", {"items": [
            {"event_id": "news123456", "revision": 1,
             "tweet": {"text": "Texto editorial verificado"}}]})
        self._write("ttittulares/decisions.json", {"items": []})
        self._write("ttittulares/site-ai-images.json", {"images": [
            {"target_id": "news123456", "revision": 1,
             "editorial_text": "Texto editorial verificado", "image_url": URL,
             "sha256": HASH}]})

    def _write(self, name, data):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(data), encoding="utf-8")

    def payload(self):
        return {"project": "ttittulares", "event_id": "news123456",
                "revision": 1, "request_id": "11111111-1111-4111-8111-111111111111"}

    def test_preflight_requires_exact_text_and_revision(self):
        with mock.patch.object(publisher, "check_image", return_value=URL):
            text, img = publisher.editorial("ttittulares", "news123456", 1)
            self.assertEqual(text, "Texto editorial verificado")
            self.assertEqual(img, URL)
            with self.assertRaisesRegex(ValueError, "revisión"):
                publisher.editorial("ttittulares", "news123456", 2)
            self._write("ttittulares/site-ai-images.json", {"images": [
                {"target_id": "news123456", "revision": 1,
                 "editorial_text": "Un texto anterior", "image_url": URL, "sha256": HASH}]})
            with self.assertRaisesRegex(ValueError, "imagen"):
                publisher.editorial("ttittulares", "news123456", 1)

    def test_no_key_is_failed_and_does_not_contact_buffer(self):
        data = {"version": 1, "items": []}
        with mock.patch.object(publisher, "graphql") as graphql:
            publisher.publish(data, self.payload(), "")
            graphql.assert_not_called()
        self.assertEqual(data["items"][0]["state"], "failed")
        self.assertIn("BUFFER_API_KEY", data["items"][0]["error"])

    def test_manual_one_tap_creates_one_post_and_blocks_duplicates(self):
        data = {"version": 1, "items": []}
        calls = []
        def api(_key, _query, variables=None):
            calls.append(variables or {})
            return {"createPost": {"post": {
                "id": "buf_123", "status": "buffer", "channelId": "channel_123"}}}
        with mock.patch.object(publisher, "check_image", return_value=URL), \
             mock.patch.object(publisher, "target_channel", return_value="channel_123"), \
             mock.patch.object(publisher, "graphql", side_effect=api):
            publisher.publish(data, self.payload(), "secret")
            publisher.publish(data, self.payload(), "secret")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["input"]["mode"], "shareNow")
        self.assertEqual(calls[0]["input"]["channelId"], "channel_123")
        self.assertEqual(calls[0]["input"]["assets"][0]["image"]["url"], URL)
        self.assertEqual(data["items"][0]["state"], "pending")
        self.assertEqual(len(data["items"]), 1)
        self.assertEqual(self.saved[0], "reservar publicación sin duplicados")

    def test_explicit_buffer_error_never_counts_as_sent(self):
        data = {"version": 1, "items": []}
        with mock.patch.object(publisher, "check_image", return_value=URL), \
             mock.patch.object(publisher, "target_channel", return_value="channel_123"), \
             mock.patch.object(publisher, "graphql",
                               return_value={"createPost": {"message": "limit reached"}}):
            publisher.publish(data, self.payload(), "secret")
        self.assertEqual(data["items"][0]["state"], "failed")
        self.assertEqual(data["items"][0]["error"], "limit reached")

    def test_network_unknown_blocks_second_post(self):
        data = {"version": 1, "items": []}
        with mock.patch.object(publisher, "check_image", return_value=URL), \
             mock.patch.object(publisher, "target_channel", return_value="channel_123"), \
             mock.patch.object(publisher, "graphql", side_effect=RuntimeError("timeout")):
            publisher.publish(data, self.payload(), "secret")
            publisher.publish(data, self.payload(), "secret")
        self.assertEqual(data["items"][0]["state"], "unknown")
        self.assertEqual(len(data["items"]), 1)

    def test_only_buffer_sent_status_is_counted(self):
        data = {"version": 1, "items": [{
            "request_id": self.payload()["request_id"], "project": "ttittulares",
            "event_id": "news123456", "revision": 1, "account": "ttittulares",
            "state": "pending", "channel_id": "channel_123",
            "buffer_post_id": "buf_123"}]}
        response = {"post": {"id": "buf_123", "channelId": "channel_123",
                             "status": "sent", "sentAt": "2026-11-06T09:00:00Z",
                             "externalLink": "https://x.com/ttittulares/status/123"}}
        with mock.patch.object(publisher, "graphql", return_value=response), \
             mock.patch.dict("os.environ", {"GH_TOKEN": ""}):
            publisher.reconcile(data, "secret")
        self.assertEqual(data["items"][0]["state"], "sent")
        self.assertEqual(data["items"][0]["post_url"],
                         "https://x.com/ttittulares/status/123")


if __name__ == "__main__":
    unittest.main()
