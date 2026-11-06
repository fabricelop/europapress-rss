import importlib.util
import json
from pathlib import Path
from email.message import Message
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
        self.real_save = publisher.save
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

    def test_reservation_commits_ledger_before_external_request(self):
        # A git diff --quiet code of 1 means there ARE staged changes.
        # Losing this commit would allow a duplicate external publication.
        staged = mock.Mock(returncode=1)
        with mock.patch.object(publisher, "save", self.real_save), \
             mock.patch.object(publisher, "run") as git, \
             mock.patch.object(publisher.subprocess, "run", return_value=staged):
            obj = {"version": 1, "items": [{"state": "reserved"}]}
            publisher.save(obj, "reservar")
        self.assertTrue(publisher.LEDGER.exists())
        calls = [call.args for call in git.call_args_list]
        self.assertTrue(any(args[:2] == ("git", "commit") for args in calls))
        self.assertTrue(any(args[:2] == ("git", "push") for args in calls))

    def test_no_change_avoids_empty_commit(self):
        staged = mock.Mock(returncode=0)
        with mock.patch.object(publisher, "save", self.real_save), \
             mock.patch.object(publisher, "run") as git, \
             mock.patch.object(publisher.subprocess, "run", return_value=staged):
            publisher.save({"version": 1, "items": []}, "sin cambios")
        calls = [call.args for call in git.call_args_list]
        self.assertFalse(any(args[:2] == ("git", "commit") for args in calls))
        self.assertFalse(any(args[:2] == ("git", "push") for args in calls))

    def test_preflight_requires_exact_revision_and_ai_identity(self):
        with mock.patch.object(publisher, "check_image", return_value=URL):
            text, img, kind = publisher.editorial("ttittulares", "news123456", 1)
            self.assertEqual((text, img, kind),
                             ("Texto editorial verificado", URL, "ai"))
            with self.assertRaisesRegex(ValueError, "revisión"):
                publisher.editorial("ttittulares", "news123456", 2)
            self._write("ttittulares/site-ai-images.json", {"images": [
                {"target_id": "news123456", "revision": 1,
                 "editorial_text": "Un texto anterior", "image_url": URL, "sha256": HASH}]})
            text, img, kind = publisher.editorial("ttittulares", "news123456", 1)
            self.assertEqual((img, kind), (None, "text"))

    def test_archive_image_when_no_ai(self):
        archive = "https://images.example.com/archived-news.jpg"
        self._write("ttittulares/site-ai-images.json", {"images": []})
        self._write("ttittulares/prepared.json", {"items": [
            {"event_id": "news123456", "revision": 1,
             "tweet": {"text": "Texto editorial verificado"},
             "archive_image": {"url": archive, "rights_status": "unverified"}}]})
        text, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual((image_url, kind), (archive, "archive"))

    def test_text_only_when_no_images(self):
        self._write("ttittulares/site-ai-images.json", {"images": []})
        text, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual(text, "Texto editorial verificado")
        self.assertEqual((image_url, kind), (None, "text"))

    def test_corrupt_ai_falls_back_to_archive_image(self):
        archive = "https://images.example.com/original.jpg"
        self._write("ttittulares/prepared.json", {"items": [
            {"event_id": "news123456", "revision": 1,
             "tweet": {"text": "Texto editorial verificado"},
             "archive_image": {"url": archive}}]})
        with mock.patch.object(publisher, "check_image",
                               side_effect=ValueError("SHA incorrecto")):
            text, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual((image_url, kind), (archive, "archive"))

    def test_buffer_text_matches_manual_x_section_link(self):
        text = "Titular contrastado y breve.\n\n#Noticias\n🌶️ Remate"
        result = publisher.x_payload("ttittulares", text)
        self.assertEqual(result, text +
                         "\n\nhttps://ttactualidad.rainyraven22.chatgpt.site/noticias")
        self.assertEqual(result.count("https://"), 1)

    def test_x_text_is_truncated_without_losing_end_hashtags_and_link(self):
        text = ("Una noticia muy larga y contrastada. " * 22) + \
            "\n\n#Actualidad #Noticias\n🌶️ Remate"
        result = publisher.x_payload("ttittulares", text)
        self.assertIn("#Actualidad #Noticias", result)
        self.assertIn("🌶️ Remate", result)
        self.assertTrue(result.endswith("/noticias"))
        self.assertLessEqual(publisher.x_weight(result.split(
            "\n\nhttps://ttactualidad.rainyraven22.chatgpt.site/noticias")[0]), 255)

    def test_rate_limit_headers_accept_buffer_spaces(self):
        headers = Message()
        headers.add_header("RateLimit-Policy",
                           '"2000-in-30days"; q=2000; w=2592000; pk=:masked:')
        headers.add_header("RateLimit",
                           '"2000-in-30days"; r=1650; t=600')
        publisher.LAST_API_QUOTA = None
        publisher.observe_rate_limits(headers)
        self.assertEqual(publisher.LAST_API_QUOTA["used"], 350)
        self.assertEqual(publisher.LAST_API_QUOTA["remaining"], 1650)

    def test_two_channels_share_one_30_day_api_quota(self):
        headers = Message()
        headers.add_header("RateLimit-Policy", '"150-in-15min";q=150;w=900;pk=:same:')
        headers.add_header("RateLimit-Policy", '"600-in-1day";q=600;w=86400;pk=:same:')
        headers.add_header("RateLimit-Policy", '"2000-in-30days";q=2000;w=2592000;pk=:same:')
        headers.add_header("RateLimit", '"150-in-15min";r=140;t=890')
        headers.add_header("RateLimit", '"600-in-1day";r=550;t=85000')
        headers.add_header("RateLimit", '"2000-in-30days";r=1732;t=2123456')
        publisher.LAST_API_QUOTA = None
        publisher.observe_rate_limits(headers)
        data = {"items": []}
        publisher.attach_latest_quota(data)
        self.assertEqual(data["api_quota"]["limit"], 2000)
        self.assertEqual(data["api_quota"]["remaining"], 1732)
        self.assertEqual(data["api_quota"]["used"], 268)
        self.assertEqual(data["api_quota"]["window_seconds"], 2592000)
        self.assertNotIn("account", data["api_quota"])

    def test_buffer_quota_policy_name_is_not_hardcoded(self):
        headers = Message()
        headers.add_header("RateLimit-Policy",
                           '"shared-api-bucket"; q=2000; w=2592000; pk=:private:')
        headers.add_header("RateLimit",
                           '"shared-api-bucket"; r=1876; t=1600')
        publisher.LAST_API_QUOTA = None
        publisher.observe_rate_limits(headers)
        self.assertEqual(publisher.LAST_API_QUOTA["remaining"], 1876)
        self.assertEqual(publisher.LAST_API_QUOTA["used"], 124)

    def test_text_only_creates_empty_assets_array(self):
        self._write("ttittulares/site-ai-images.json", {"images": []})
        calls = []
        def api(_key, _query, variables=None):
            calls.append(variables)
            return {"createPost": {"post": {
                "id": "buf_text", "status": "buffer", "channelId": "channel_123"}}}
        with mock.patch.object(publisher, "target_channel", return_value="channel_123"), \
             mock.patch.object(publisher, "graphql", side_effect=api):
            state = {"version": 1, "items": []}
            publisher.publish(state, self.payload(), "secret")
        self.assertEqual(calls[0]["input"]["assets"], [])
        self.assertEqual(state["items"][0]["media_type"], "text")

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
