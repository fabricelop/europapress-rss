#!/usr/bin/env python3
"""Pruebas offline de /run; nunca contactan Telegram ni GitHub."""
import base64
import io
import json
import os
import sys
import unittest
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
os.environ.setdefault("TTENDENCIAS_BOT_TOKEN", "test-token")
os.environ.setdefault("GH_TOKEN", "test-token")
from trends import telegram_bot as bot


class Reply(io.BytesIO):
    def __init__(self, payload, status=200):
        super().__init__(json.dumps(payload).encode())
        self.status = status
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.close()


class TelegramRunTests(unittest.TestCase):
    def test_existing_trigger_schema(self):
        writes = []
        existing = {
            "version": 2, "command_id": "tr-old",
            "requested_at": "2026-09-01T00:00:00Z"
        }
        def urlopen(request, timeout=20):
            if isinstance(request, urllib.request.Request) and request.get_method() == "PUT":
                payload = json.loads(request.data)
                doc = json.loads(base64.b64decode(payload["content"]))
                writes.append((payload, doc))
                return Reply({"content": {"sha": "new"}}, 200)
            return Reply({"sha": "old", "content": base64.b64encode(json.dumps(existing).encode()).decode()})
        with patch.object(urllib.request, "urlopen", side_effect=urlopen):
            result = bot.request_windows_editorial_run()
        self.assertEqual(result["status"], "requested")
        self.assertEqual(len(writes), 1)
        payload, doc = writes[0]
        self.assertEqual(payload["branch"], "control/ttendencias-run-trigger")
        self.assertEqual(doc["project"], "ttendencias")
        self.assertEqual(doc["launcher_arg"], "tendencias")
        self.assertEqual(doc["executor"], "pc_chat_ttendencias_dedicated")
        self.assertEqual(doc["command_id"], result["command_id"])

    def test_duplicate_recent_trigger(self):
        now = datetime.now(timezone.utc).isoformat()
        existing = {"command_id": "tr-recent", "requested_at": now}
        def urlopen(request, timeout=20):
            self.assertNotEqual(request.get_method(), "PUT")
            return Reply({"sha": "old", "content": base64.b64encode(json.dumps(existing).encode()).decode()})
        with patch.object(urllib.request, "urlopen", side_effect=urlopen):
            result = bot.request_windows_editorial_run()
        self.assertEqual(result, {"status": "already_requested", "command_id": "tr-recent"})

    def test_wrong_chat_cannot_launch(self):
        messages = []
        with patch.object(bot, "load", return_value={"chat_id": 1234}), \
             patch.object(bot, "request_windows_editorial_run", side_effect=AssertionError("Must not run")), \
             patch.object(bot, "call", side_effect=lambda *args, **kwargs: messages.append(args)):
            handled = bot.handle_run_command({"text": "/run", "chat": {"id": 9999, "type": "private"}})
        self.assertTrue(handled)
        self.assertEqual(messages, [])

    def test_valid_command_ack(self):
        notes = []
        with patch.object(bot, "load", return_value={"chat_id": 1234}), \
             patch.object(bot, "request_windows_editorial_run",
                          return_value={"status": "requested", "command_id": "tr-mock"}), \
             patch.object(bot, "call", side_effect=lambda method, data: notes.append((method, data))):
            handled = bot.handle_run_command({"text": "/run", "chat": {"id": 1234, "type": "private"}})
        self.assertTrue(handled)
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0][0], "sendMessage")
        self.assertIn("solicitud /run guardada", notes[0][1]["text"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
