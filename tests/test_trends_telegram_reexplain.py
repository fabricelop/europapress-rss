#!/usr/bin/env python3
"""Offline regression tests for the active TTendencias Telegram listener."""
import copy
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("TTENDENCIAS_BOT_TOKEN", "test-token-for-offline-tests")
SOURCE = Path(__file__).resolve().parents[1] / "trends" / "telegram_bot.py"
spec = importlib.util.spec_from_file_location("tt_telegram_module_under_test", SOURCE)
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


def callback(action="r", sender="456", chat="456", message_id=681):
    return {
        "id": "callback-test-123",
        "data": "tx:" + action + ":abc123xyz:2",
        "from": {"id": int(sender)},
        "message": {
            "message_id": message_id,
            "chat": {"id": int(chat), "type": "private"},
        },
    }


class ReexplainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.requests_path = Path(self.tmp.name) / "requests.json"
        self.queue_path = Path(self.tmp.name) / "editorial-queue.json"
        self.docs = {
            "trends/telegram-bot-state.json": {"chat_id": 456},
            "trends/telegram-image-deliveries.json": {
                "items": [{"event_id": "abc123xyz", "revision": 2,
                           "telegram_message_id": 681,
                           "title": "La Cartuja", "name": "La Cartuja",
                           "status": "sent"}]},
            "trends/requests.json": {"requests": [
                {"id": "abc123xyz", "name": "La Cartuja",
                 "revision": 2, "status": "explained"}]},
        }
        self.persist_calls = []

        def remote(path, fallback):
            return copy.deepcopy(self.docs.get(path, fallback))

        def persist(message):
            self.persist_calls.append(message)
            return True

        self.p1 = patch.object(bot, "REQUESTS", self.requests_path)
        self.p2 = patch.object(bot, "load_remote_json", side_effect=remote)
        self.p3 = patch.object(bot, "persist_package_state", side_effect=persist)
        self.p4 = patch.object(bot, "EDITORIAL_QUEUE", self.queue_path)
        self.p1.start(); self.p2.start(); self.p3.start(); self.p4.start()
        self.addCleanup(self.p1.stop)
        self.addCleanup(self.p2.stop)
        self.addCleanup(self.p3.stop)
        self.addCleanup(self.p4.stop)

    def test_group_followers_route_to_single_leader(self):
        group_id = "grp-same-match"
        self.docs["trends/requests.json"]["requests"] = [
            {"id":"abc123xyz","name":"Fofana","revision":2,"status":"explained",
             "group_id":group_id,"group_leader_id":"match"},
            {"id":"match","name":"Levante-Sevilla","revision":1,"status":"explained",
             "group_id":group_id,"group_leader_id":"match"},
        ]
        self.docs["trends/telegram-image-deliveries.json"]["items"].append({
            "event_id":"match","revision":1,"telegram_message_id":682,"status":"sent",
            "group_id":group_id,
        })
        self.assertEqual(bot.handle_readonly_reexplain(callback()), "queued")
        reqs = bot.load(self.requests_path, {"requests":[]})["requests"]
        self.assertEqual(reqs[0]["status"], "explained")
        self.assertEqual(reqs[1]["status"], "update")
        self.assertEqual(reqs[1]["revision"], 3)
        rows=bot.load(self.queue_path,{"items":[]})["items"]
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]["id"],"match")

    def test_button_creates_revision_and_instruction(self):
        result = bot.handle_readonly_reexplain(callback())
        self.assertEqual(result, "queued")
        row = bot.load(self.requests_path, {"requests": []})["requests"][0]
        self.assertEqual(row["revision"], 3)
        self.assertEqual(row["status"], "update")
        self.assertTrue(row["reexplain"])
        self.assertEqual(row["request_source"], "telegram_reexplain")
        self.assertIn("ACTUALIZADA", row["reexplain_instructions"])
        self.assertEqual(len(self.persist_calls), 1)

    def test_reply_preserves_requested_context(self):
        result = bot.handle_readonly_reexplain(
            callback(), "Comprueba el resultado final del partido")
        self.assertEqual(result, "queued")
        row = bot.load(self.requests_path, {"requests": []})["requests"][0]
        self.assertEqual(row["rewrite_instruction"], "Comprueba el resultado final del partido")

    def test_wrong_message_not_accepted(self):
        self.assertEqual(bot.handle_readonly_reexplain(callback(message_id=999)),
                         "not_active")
        self.assertFalse(self.persist_calls)

    def test_foreign_sender_not_accepted(self):
        self.assertEqual(bot.handle_readonly_reexplain(callback(sender="999")),
                         "unauthorized")
        self.assertFalse(self.persist_calls)

    def test_deleted_message_cannot_be_reopened(self):
        self.docs["trends/telegram-image-deliveries.json"]["items"][0]["status"] = "deleted"
        self.assertEqual(bot.handle_readonly_reexplain(callback()), "not_active")

    def test_existing_pending_reexplanation_not_duplicated(self):
        row = self.docs["trends/requests.json"]["requests"][0]
        row.update(status="update", reexplain=True)
        self.assertEqual(bot.handle_readonly_reexplain(callback()), "already_pending")
        self.assertFalse(self.persist_calls)


if __name__ == "__main__":
    unittest.main()
