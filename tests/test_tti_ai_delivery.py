"""No entrega tardía, reloj real y respuesta única de IA para Telegram."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch

from shared import telegram_readonly_delivery as telegram


class AiDeliveryTests(TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 13, 21, 30, tzinfo=timezone.utc)
        self.command = "tt-img-auto-abc-r1-a1-123"
        self.item = {
            "event_id": "abc", "revision": 1, "prepared_at": "2026-10-13T21:29:00Z",
            "ai_image_status": "none",
        }

    def fake_info(self, item, job):
        class Answer:
            ok = True
            def json(self):
                return job
        with patch.dict("os.environ", {"TELEGRAM_BOT_TOKEN": "test"}), \
             patch.object(telegram.requests, "get", return_value=Answer()):
            return telegram.ai_delivery_info(item, self.now)

    def job(self, status="RUNNING", seconds=60):
        return {
            "target_id": "abc", "revision": 1, "command_id": self.command,
            "status": status, "auto_repair": True,
            "pc_launched_at": (self.now-timedelta(seconds=seconds)).isoformat(),
        }

    def generated(self, command=None):
        return {
            **self.item, "ai_image_status": "ready",
            "ai_image": {
                "url": "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/ttittulares/generated-images/a.jpg",
                "generated": True, "provider": "chat-imagegen", "origin": "executing_chat",
                "sha256": "a" * 64, "width": 1536, "height": 864,
                "context_guard": {"event_id": "abc", "revision": 1,
                                  "command_id": command if command is not None else self.command},
            },
        }

    def test_five_minutes_only_after_real_launch(self):
        queued = self.job("REQUESTED")
        queued.pop("pc_launched_at")
        state = self.fake_info(self.item, queued)
        self.assertIn("pendiente de lanzamiento", state["note"])
        state = self.fake_info(self.item, self.job(seconds=60))
        self.assertIn("en curso", state["note"])
        state = self.fake_info(self.item, self.job(seconds=301))
        self.assertIn("no disponible", state["note"])

    def test_automatic_image_must_reach_telegram_before_deadline(self):
        ready = self.generated()
        self.assertTrue(self.fake_info(ready, self.job(seconds=40))["url"])
        self.assertFalse(self.fake_info(ready, self.job("DONE", seconds=301))["url"])

    def test_manual_generation_is_never_cancelled_by_automatic_deadline(self):
        ready = self.generated("tt-img-manual-123")
        self.assertTrue(self.fake_info(ready, self.job("ERROR", seconds=400))["url"])

    def test_automatic_not_delivered_without_confirmed_launch(self):
        ready = self.generated()
        pending = self.job("REQUESTED")
        pending.pop("pc_launched_at")
        self.assertFalse(self.fake_info(ready, pending)["url"])

    def test_ai_companion_is_one_reply_per_original_and_ledger_saved(self):
        with TemporaryDirectory() as folder:
            with patch.object(telegram, "ROOT", Path(folder)), \
                 patch.object(telegram, "archival_image", return_value=(b"jpeg", "image/jpeg", "gag.jpg")), \
                 patch.object(telegram, "send", return_value={"message_id": 98}) as send:
                row = {"event_id": "abc", "status": "sent", "telegram_message_id": 95}
                ledger = {"items": [row]}
                card = {"ai_url": self.generated()["ai_image"]["url"], "title": "Titular"}
                self.assertTrue(telegram.attach_news_ai(card, row, "token", "chat",
                               "telegram/ttittulares-deliveries.json", ledger, self.now))
                self.assertFalse(telegram.attach_news_ai(card, row, "token", "chat",
                                "telegram/ttittulares-deliveries.json", ledger, self.now))
                self.assertEqual(send.call_count, 1)
                self.assertEqual(send.call_args.args[2]["reply_to_message_id"], 95)
                saved = telegram.load("telegram/ttittulares-deliveries.json", {})
                self.assertEqual(saved["items"][0]["ai_telegram_message_id"], 98)
