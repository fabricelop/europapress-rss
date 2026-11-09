import importlib.util
import json
import hashlib
from datetime import datetime, timedelta, timezone
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
        # Unit tests are offline. Fetching the public approved-image feed is
        # exercised separately with a complete mocked HTTP response.
        self.read_approved = publisher.approved_catalog_candidates
        public = mock.patch.object(publisher, "approved_catalog_candidates",
                                   return_value=[])
        public.start()
        self.addCleanup(public.stop)
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


    def test_recent_verified_channel_avoids_two_buffer_lookups(self):
        now = datetime.now(timezone.utc)
        sent = (now - timedelta(minutes=40)).isoformat()
        row = {"account": "ttittulares", "state": "sent",
               "channel_id": "trusted-channel-1", "sent_at": sent,
               "post_url": "https://x.com/ttittulares/status/1234567890123456789"}
        ledger = {"items": [row]}
        self.assertEqual(publisher.recent_verified_channel(
            ledger, "ttittulares", now), "trusted-channel-1")
        self.assertIsNone(publisher.recent_verified_channel(
            ledger, "ttendenciasesp", now))
        expired = now + timedelta(hours=8)
        self.assertIsNone(publisher.recent_verified_channel(
            ledger, "ttittulares", expired))
        row["post_url"] = "https://x.com/otheraccount/status/1234567890123456789"
        self.assertIsNone(publisher.recent_verified_channel(
            ledger, "ttittulares", now))

    def test_disconnected_channel_invalidates_verified_cache(self):
        now = datetime.now(timezone.utc)
        sent = (now - timedelta(minutes=40)).isoformat()
        row = {"account": "ttittulares", "state": "sent",
               "channel_id": "trusted-channel-1", "sent_at": sent,
               "post_url": "https://x.com/ttittulares/status/1234567890123456789"}
        ledger = {"items": [row], "channel_cache_invalid_after":
                  {"ttittulares": now.isoformat()}}
        self.assertIsNone(publisher.recent_verified_channel(
            ledger, "ttittulares", now))

    def test_stale_pending_does_not_poll_every_quarter_hour(self):
        now = datetime.now(timezone.utc)
        item = {"state": "pending", "buffer_post_id": "buffer-123",
                "requested_at": (now - timedelta(hours=34)).isoformat(),
                "last_buffer_check_at": (now - timedelta(minutes=20)).isoformat()}
        self.assertFalse(publisher.pending_check_due(item, now))
        with mock.patch.object(publisher, "graphql") as api:
            publisher.reconcile({"items": [item]}, "test-key")
            api.assert_not_called()
        self.assertEqual(item["state"], "pending")

    def test_old_pending_is_rechecked_after_twelve_hours_without_new_post(self):
        now = datetime.now(timezone.utc)
        item = {"state": "pending", "buffer_post_id": "buffer-123",
                "requested_at": (now - timedelta(hours=34)).isoformat(),
                "last_buffer_check_at": (now - timedelta(hours=13)).isoformat(),
                "account": "ttittulares", "channel_id": "channel-1"}
        response = {"post": {"id": "buffer-123", "channelId": "channel-1",
                             "status": "queued"}}
        with mock.patch.object(publisher, "graphql", return_value=response) as api:
            publisher.reconcile({"items": [item]}, "test-key")
            self.assertEqual(api.call_count, 1)
        self.assertEqual(item["state"], "pending")
        self.assertEqual(item["buffer_poll_attempts"], 1)
        self.assertTrue(item.get("last_buffer_check_at"))
        self.assertFalse(publisher.pending_check_due(item, now))

    def test_recent_pending_checks_still_run_each_fifteen_minutes(self):
        now = datetime.now(timezone.utc)
        item = {"state": "pending", "buffer_post_id": "new-post",
                "requested_at": (now - timedelta(minutes=25)).isoformat(),
                "last_buffer_check_at": (now - timedelta(minutes=17)).isoformat()}
        self.assertTrue(publisher.pending_check_due(item, now))
        item["last_buffer_check_at"] = (now - timedelta(minutes=9)).isoformat()
        self.assertFalse(publisher.pending_check_due(item, now))

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

    def test_repo_archive_photo_is_selected_with_exact_event_identity(self):
        self._write("ttittulares/site-ai-images.json", {"images": []})
        root = self.root / "ttittulares/archive-images"
        root.mkdir(parents=True)
        (root / "news123456-r1-archived.jpg").write_bytes(b"archive")
        (root / "unrelated-r1-archived.jpg").write_bytes(b"wrong")
        (root / "news123456-r2-future.jpg").write_bytes(b"future")
        _, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual(kind, "archive")
        self.assertEqual(image_url,
                         "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
                         "ttittulares/archive-images/news123456-r1-archived.jpg")

    def test_archive_previous_revision_is_preserved_for_same_news(self):
        self._write("ttittulares/site-ai-images.json", {"images": []})
        root = self.root / "ttittulares/archive-images"
        root.mkdir(parents=True)
        (root / "news123456-r0-archived.jpg").write_bytes(b"archive")
        _, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual(kind, "archive")
        self.assertIn("news123456-r0-archived.jpg", image_url)

    def test_archive_rights_denial_falls_back_to_text(self):
        self._write("ttittulares/site-ai-images.json", {"images": []})
        root = self.root / "ttittulares/archive-images"
        root.mkdir(parents=True)
        (root / "news123456-r1-archived.jpg").write_bytes(b"archive")
        self._write("ttittulares/prepared.json", {"items": [
            {"event_id": "news123456", "revision": 1,
             "tweet": {"text": "Texto editorial verificado"},
             "archive_image": {"rights_status": "denied"}}]})
        _, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual((image_url, kind), (None, "text"))

    def test_text_only_when_no_images(self):
        self._write("ttittulares/site-ai-images.json", {"images": []})
        text, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual(text, "Texto editorial verificado")
        self.assertEqual((image_url, kind), (None, "text"))

    def test_corrupt_exact_ai_blocks_publication_instead_of_archive(self):
        archive = "https://images.example.com/original.jpg"
        self._write("ttittulares/prepared.json", {"items": [
            {"event_id": "news123456", "revision": 1,
             "tweet": {"text": "Texto editorial verificado"},
             "archive_image": {"url": archive}}]})
        with mock.patch.object(publisher, "check_image",
                               side_effect=ValueError("SHA incorrecto")):
            with self.assertRaisesRegex(ValueError, "Hay imagen IA aprobada"):
                publisher.editorial("ttittulares", "news123456", 1)

    def test_public_approved_ia_takes_priority_over_archive_and_git_catalog(self):
        approved = "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttittulares/news123456-r1-manual-" + "b"*12 + ".png"
        archive = "https://images.example.com/news-archive.jpg"
        self._write("ttittulares/prepared.json", {"items": [{
            "event_id": "news123456", "revision": 1,
            "tweet": {"text": "Texto editorial verificado"},
            "archive_image": {"url": archive}}]})
        with mock.patch.object(publisher, "approved_catalog_candidates", return_value=[
              {"image_url": approved, "sha256": "b"*64}]), \
             mock.patch.object(publisher, "check_image", return_value=approved) as check:
            text, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual((image_url, kind), (approved, "ai"))
        check.assert_called_once_with(approved, "b"*64, "ttittulares", "news123456", 1)

    def test_user_uploaded_trend_github_image_is_valid_without_second_approval(self):
        # The iOS "Subir y aprobar" GitHub fallback stores user-selected PNGs
        # under trends/generated-images, NOT ttendencias/generated-images.
        # Its authenticated, exact-identity manifest is itself approval.
        png = b"\x89PNG\r\n\x1a\n" + b"editor-submitted-image" * 80
        sha = hashlib.sha256(png).hexdigest()
        event_id = "espanyoltest123"
        filename = event_id + "-r0-manual-" + sha[:12] + ".png"
        url = ("https://raw.githubusercontent.com/fabricelop/europapress-rss/"
               "main/trends/generated-images/" + filename)
        explanation = "TT#8 Espanyol es tendencia por el encuentro de Liga."
        at = "2026-11-07T22:00:00+01:00"
        self._write("trends/telegram-manual-explained.json", {"items": [
            {"id": event_id, "revision": 0, "status": "explained",
             "explanation": explanation, "explained_at": at}]})
        self._write("trends/mobile-decisions.json", {"items": []})
        self._write("trends/site-ai-images.json", {"images": [
            {"target_id": event_id, "revision": 0,
             "explanation": explanation, "explained_at": at,
             "image_url": url, "sha256": sha}]})
        archive = self.root / "trends/archive-images"
        archive.mkdir(parents=True)
        (archive / (event_id + "-r0-file.jpg")).write_bytes(b"archive")

        class Reply:
            def __enter__(self): return self
            def __exit__(self, *_args): return False
            def geturl(self): return url
            def read(self, limit): return png[:limit]

        calls = []
        def buffer_api(_key, _query, variables=None):
            calls.append(variables)
            return {"createPost": {"post": {
                "id": "buffer-test-only", "status": "buffer",
                "channelId": "trend_channel_test"}}}
        payload = {"project": "ttendencias", "event_id": event_id,
                   "revision": 0,
                   "request_id": "22222222-2222-4222-8222-222222222222"}
        with mock.patch.object(publisher, "urlopen", return_value=Reply()), \
             mock.patch.object(publisher, "target_channel",
                               return_value="trend_channel_test"), \
             mock.patch.object(publisher, "graphql", side_effect=buffer_api):
            text, chosen, media = publisher.editorial("ttendencias", event_id, 0)
            self.assertEqual((text, chosen, media), (explanation, url, "ai"))
            state = {"version": 1, "items": []}
            publisher.publish(state, payload, "test-key")
            publisher.publish(state, payload, "test-key")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["input"]["assets"],
                         [{"image": {"url": url}}])
        self.assertEqual(state["items"][0]["media_type"], "ai")

    def test_github_manual_trend_image_rejects_wrong_identity_and_digest(self):
        png = b"\x89PNG\r\n\x1a\n" + b"editor-original" * 30
        sha = hashlib.sha256(png).hexdigest()
        prefix = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
        correct = prefix + "trends/generated-images/trend123-r0-manual-" + sha[:12] + ".png"
        class Reply:
            def __enter__(self): return self
            def __exit__(self, *_args): return False
            def geturl(self): return correct
            def read(self, limit): return png[:limit]
        with mock.patch.object(publisher, "urlopen", return_value=Reply()):
            self.assertEqual(publisher.check_image(
                correct, sha, "ttendencias", "trend123", 0), correct)
            for invalid in [
                    correct.replace("trends/generated-images",
                                    "ttendencias/generated-images"),
                    correct.replace("trend123-r0", "trend999-r0"),
                    correct.replace("trend123-r0", "trend123-r1")]:
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    publisher.check_image(
                        invalid, sha, "ttendencias", "trend123", 0)
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                publisher.check_image(correct, "f" * 64,
                                      "ttendencias", "trend123", 0)

    def test_approved_espanyol_redirect_to_canonical_site_is_verified(self):
        png = b"\x89PNG\r\n\x1a\n" + b"test-exact-original" * 100
        sha = hashlib.sha256(png).hexdigest()
        name = "1edd6ef875e4-r0-" + sha[:12] + ".png"
        source = ("https://ttactualidad-tendencias.rainyraven22.chatgpt.site"
                  "/images/ttendencias/" + name)
        canonical = ("https://ttactualidad.rainyraven22.chatgpt.site"
                     "/images/ttendencias/" + name)

        class Response:
            def __init__(self, final_url): self.final_url = final_url
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def geturl(self): return self.final_url
            def read(self, limit): return png[:limit]

        with mock.patch.object(publisher, "urlopen", return_value=Response(canonical)):
            self.assertEqual(
                publisher.check_image(source, sha, "ttendencias", "1edd6ef875e4", 0),
                canonical)
        for invalid in [
                canonical.replace("ttactualidad.rainyraven22.chatgpt.site",
                                  "wrong.example.net"),
                canonical.replace("1edd6ef875e4-r0-", "another-episode-r0-"),
                canonical + "?untrusted=1",
                canonical.replace("https://", "http://")]:
            with self.subTest(invalid=invalid):
                with mock.patch.object(publisher, "urlopen",
                                       return_value=Response(invalid)):
                    with self.assertRaises(ValueError):
                        publisher.check_image(
                            source, sha, "ttendencias", "1edd6ef875e4", 0)
        with mock.patch.object(publisher, "urlopen",
                               return_value=Response(canonical)), \
             mock.patch.object(publisher.hashlib, "sha256",
                               return_value=mock.Mock(hexdigest=lambda: "0"*64)):
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                publisher.check_image(source, sha, "ttendencias", "1edd6ef875e4", 0)

    def test_unverified_approved_ai_never_calls_buffer_or_publishes_text(self):
        approved = ("https://ttactualidad-tendencias.rainyraven22.chatgpt.site"
                    "/images/ttittulares/news123456-r1-broken.png")
        with mock.patch.object(publisher, "approved_catalog_candidates",
                               return_value=[{"image_url": approved, "sha256": "b"*64}]), \
             mock.patch.object(publisher, "check_image",
                               side_effect=ValueError("Imagen temporalmente inaccesible")), \
             mock.patch.object(publisher, "target_channel") as channel, \
             mock.patch.object(publisher, "graphql") as graphql:
            ledger = {"version": 1, "items": []}
            publisher.publish(ledger, self.payload(), "dummy-key")
            self.assertEqual(ledger["items"][0]["state"], "failed")
            self.assertIn("Hay imagen IA aprobada", ledger["items"][0]["error"])
            channel.assert_not_called()
            graphql.assert_not_called()

    def test_site_approved_feed_validates_exact_identity_and_rejects_other_news(self):
        class FakeReply:
            status = 200
            def __init__(self, url, body):
                self.url, self.body = url, body
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def geturl(self): return self.url
            def read(self, limit): return self.body[:limit]
        target = {
            "approval_id": "c"*64, "target_id": "news123456", "revision": 1,
            "editorial_text": "Texto editorial verificado",
            "prepared_at": "2026-11-07T12:00:00Z",
            "image_url": URL, "sha256": HASH}
        body = json.dumps({
            "schema_version": 1, "project": "ttittulares",
            "project_id": publisher.APPROVED_PROJECT_ID,
            "images": [{**target, "target_id": "other"}, target,
                       {**target, "editorial_text": "changed"},
                       {**target, "approval_id": ""}]}).encode()
        with mock.patch.object(publisher, "urlopen", side_effect=lambda req, timeout:
                FakeReply(req.full_url, body)):
            rows = self.read_approved("ttittulares", "news123456", 1,
                "Texto editorial verificado", "2026-11-07T12:00:00Z")
            other = self.read_approved("ttittulares", "news123456", 2,
                "Texto editorial verificado", "2026-11-07T12:00:00Z")
        self.assertEqual(rows, [{"image_url": URL, "sha256": HASH}])
        self.assertEqual(other, [])

    def test_unavailable_approved_feed_preserves_archive_fallback(self):
        archive = "https://images.example.com/article.jpg"
        self._write("ttittulares/site-ai-images.json", {"images": []})
        self._write("ttittulares/prepared.json", {"items": [{
            "event_id": "news123456", "revision": 1,
            "tweet": {"text": "Texto editorial verificado"},
            "archive_image": {"url": archive}}]})
        with mock.patch.object(publisher, "approved_catalog_candidates", return_value=[]):
            _, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual((image_url, kind), (archive, "archive"))

    def test_second_approved_ai_is_used_if_first_catalog_url_is_broken(self):
        stale = URL
        verified = URL.replace("test-r1.png", "news123456-r1-ai2.png")
        self._write("ttittulares/site-ai-images.json", {"images": [
            {"target_id": "news123456", "revision": 1,
             "editorial_text": "Texto editorial verificado",
             "image_url": stale, "sha256": HASH},
            {"target_id": "news123456", "revision": 1,
             "editorial_text": "Texto editorial verificado",
             "image_url": verified, "sha256": "b" * 64},
        ]})
        def verify(url, sha, project, event_id, revision):
            self.assertEqual((project, event_id, revision),
                             ("ttittulares", "news123456", 1))
            if url == stale:
                raise ValueError("Original verificado no disponible")
            self.assertEqual((url, sha), (verified, "b" * 64))
            return url
        with mock.patch.object(publisher, "check_image", side_effect=verify) as check:
            _, image_url, kind = publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual((image_url, kind), (verified, "ai"))
        self.assertEqual(check.call_count, 2)

    def test_duplicate_approved_catalog_rows_are_checked_only_once(self):
        self._write("ttittulares/site-ai-images.json", {"images": [
            {"target_id": "news123456", "revision": 1,
             "editorial_text": "Texto editorial verificado",
             "image_url": URL, "sha256": HASH},
            {"target_id": "news123456", "revision": 1,
             "editorial_text": "Texto editorial verificado",
             "image_url": URL, "sha256": HASH},
        ]})
        with mock.patch.object(publisher, "check_image",
                               side_effect=ValueError("Archivo roto")) as check:
            with self.assertRaisesRegex(ValueError, "Hay imagen IA aprobada"):
                publisher.editorial("ttittulares", "news123456", 1)
        self.assertEqual(check.call_count, 1)

    def test_both_x_accounts_end_at_working_site_homepage(self):
        text = "Titular contrastado y breve.\n\n#Noticias\n🌶️ Remate"
        for project in ("ttittulares", "ttendencias"):
            with self.subTest(project=project):
                result = publisher.x_payload(project, text)
                self.assertEqual(result, text +
                                 "\n\nhttps://ttactualidad.rainyraven22.chatgpt.site/")
                self.assertEqual(result.count("https://"), 1)

    def test_legacy_section_footer_is_replaced_not_duplicated(self):
        base = "Texto editorial con remate y #Etiqueta"
        old_urls = (
            "https://ttactualidad.rainyraven22.chatgpt.site/noticias",
            "https://ttactualidad.rainyraven22.chatgpt.site/tendencias",
        )
        for project in ("ttittulares", "ttendencias"):
            for old in old_urls:
                with self.subTest(project=project, old=old):
                    result = publisher.x_payload(project, base + "\n\n" + old)
                    self.assertEqual(result, base +
                                     "\n\nhttps://ttactualidad.rainyraven22.chatgpt.site/")
        unrelated = "Enlace de fuente https://example.org/informe"
        self.assertIn(unrelated, publisher.x_payload("ttittulares", unrelated))

    def test_x_text_is_truncated_without_losing_end_hashtags_and_link(self):
        text = ("Una noticia muy larga y contrastada. " * 22) + \
            "\n\n#Actualidad #Noticias\n🌶️ Remate"
        result = publisher.x_payload("ttittulares", text)
        self.assertIn("#Actualidad #Noticias", result)
        self.assertIn("🌶️ Remate", result)
        self.assertTrue(result.endswith("https://ttactualidad.rainyraven22.chatgpt.site/"))
        self.assertLessEqual(publisher.x_weight(result.split(
            "\n\nhttps://ttactualidad.rainyraven22.chatgpt.site/")[0]), 255)

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

    def test_posts_never_attach_a_website_xcard_asset(self):
        self.assertEqual(publisher.x_post_assets(None), [])
        url = "https://example.org/approved-original.png"
        self.assertEqual(publisher.x_post_assets(url),
                         [{"image": {"url": url}}])
        # Both accounts share the visible text link and no card asset.
        for project in ("ttittulares", "ttendencias"):
            self.assertTrue(publisher.x_payload(project, "Texto").endswith(
                "https://ttactualidad.rainyraven22.chatgpt.site/"))

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
                             "externalLink": "https://x.com/ttittulares/status/123456"}}
        with mock.patch.object(publisher, "graphql", return_value=response), \
             mock.patch.dict("os.environ", {"GH_TOKEN": ""}):
            publisher.reconcile(data, "secret")
        self.assertEqual(data["items"][0]["state"], "sent")
        self.assertEqual(data["items"][0]["post_url"],
                         "https://x.com/ttittulares/status/123456")


    def test_x_permalink_requires_exact_destination_and_real_status_id(self):
        self.assertTrue(publisher.verified_x_link(
            "https://x.com/ttendenciasesp/status/123456", "ttendenciasesp"))
        self.assertTrue(publisher.verified_x_link(
            "https://twitter.com/TTiTTulares/status/1234567?s=20", "ttittulares"))
        self.assertFalse(publisher.verified_x_link(
            "https://x.com/other/status/123456", "ttendenciasesp"))
        self.assertFalse(publisher.verified_x_link(
            "https://notx.com/ttendenciasesp/status/123456", "ttendenciasesp"))
        self.assertFalse(publisher.verified_x_link(
            "https://x.com/ttendenciasesp", "ttendenciasesp"))
        self.assertFalse(publisher.verified_x_link(
            "https://x.com/ttendenciasesp/status/fake", "ttendenciasesp"))

    def test_sent_without_matching_x_link_is_pending_and_never_closes(self):
        data = {"items": [{
            "request_id": self.payload()["request_id"], "project": "ttittulares",
            "event_id": "news123456", "revision": 1, "account": "ttittulares",
            "state": "pending", "channel_id": "channel_123",
            "buffer_post_id": "buf_123"}]}
        response = {"post": {"id": "buf_123", "channelId": "channel_123",
                             "status": "sent", "sentAt": "2026-11-07T09:00:00Z",
                             "externalLink": "https://x.com/other/status/123456"}}
        with mock.patch.object(publisher, "graphql", return_value=response), \
             mock.patch.object(publisher, "urlopen") as send, \
             mock.patch.dict("os.environ", {"GH_TOKEN": "should-not-be-used"}):
            publisher.reconcile(data, "secret")
            send.assert_not_called()
        self.assertEqual(data["items"][0]["state"], "pending")
        self.assertNotIn("closure_request_id", data["items"][0])
        self.assertIn("sin enlace verificable", data["items"][0]["verification_note"])

    def test_initial_buffer_sent_mutation_is_not_proof_until_readback(self):
        data = {"version": 1, "items": []}
        response = {"createPost": {"post": {
            "id": "buf_123", "channelId": "channel_123", "status": "sent",
            "sentAt": "2026-11-07T09:00:00Z",
            "externalLink": "https://x.com/ttittulares/status/123456"}}}
        with mock.patch.object(publisher, "target_channel", return_value="channel_123"), \
             mock.patch.object(publisher, "graphql", return_value=response), \
             mock.patch.object(publisher, "check_image", return_value=URL):
            publisher.publish(data, self.payload(), "secret")
        self.assertEqual(data["items"][0]["state"], "pending")
        self.assertNotIn("closure_request_id", data["items"][0])
        self.assertNotIn("post_url", data["items"][0])

    def test_closure_requires_committed_github_receipt(self):
        data = {"items": [{
            "request_id": self.payload()["request_id"], "project": "ttittulares",
            "event_id": "news123456", "revision": 1, "account": "ttittulares",
            "state": "sent", "channel_id": "channel_123",
            "buffer_post_id": "buf_123", "sent_at": "2026-11-07T09:00:00Z",
            "post_url": "https://x.com/ttittulares/status/123456",
            "closure_request_id": "22222222-2222-4222-8222-222222222222",
            "closure_dispatched": True}]}
        with mock.patch.object(publisher, "closure_receipt", return_value=None), \
             mock.patch.object(publisher, "urlopen") as send:
            publisher.reconcile(data, "secret")
            send.assert_not_called()
        self.assertFalse(data["items"][0].get("closure_verified", False))
        with mock.patch.object(publisher, "closure_receipt",
                               return_value={"status": "applied", "project": "ttittulares",
                                             "event_id": "news123456", "revision": 1,
                                             "decision": "published"}), \
             mock.patch.object(publisher, "urlopen") as send:
            publisher.reconcile(data, "secret")
            send.assert_not_called()
        self.assertTrue(data["items"][0]["closure_verified"])

    def test_rejected_closure_does_not_claim_listas_removed(self):
        data = {"items": [{
            "project": "ttendencias", "event_id": "50d1a6619b2a",
            "revision": 0, "account": "ttendenciasesp",
            "state": "sent", "channel_id": "channel_123",
            "buffer_post_id": "buf_123", "closure_dispatched": True,
            "closure_request_id": "22222222-2222-4222-8222-222222222222"}]}
        with mock.patch.object(publisher, "closure_receipt",
                               return_value={"status": "rejected", "project": "ttendencias",
                                             "event_id": "50d1a6619b2a", "revision": 0,
                                             "decision": "published"}), \
             mock.patch.object(publisher, "urlopen") as send:
            publisher.reconcile(data, "secret")
            send.assert_not_called()
        self.assertFalse(data["items"][0].get("closure_verified", False))
        self.assertIn("rechazado", data["items"][0]["closure_error"])


    def test_wrong_editorial_receipt_cannot_remove_another_trend(self):
        data = {"items": [{
            "project": "ttendencias", "event_id": "50d1a6619b2a",
            "revision": 0, "account": "ttendenciasesp",
            "state": "sent", "channel_id": "channel_123",
            "buffer_post_id": "buf_123", "closure_dispatched": True,
            "closure_request_id": "22222222-2222-4222-8222-222222222222"}]}
        receipt = {"status": "applied", "project": "ttendencias",
                   "event_id": "other-id", "revision": 0,
                   "decision": "published"}
        with mock.patch.object(publisher, "closure_receipt", return_value=receipt), \
             mock.patch.object(publisher, "urlopen") as send:
            publisher.reconcile(data, "secret")
            send.assert_not_called()
        self.assertFalse(data["items"][0].get("closure_verified", False))
        self.assertIn("no coincide", data["items"][0]["closure_error"])


if __name__ == "__main__":
    unittest.main()
