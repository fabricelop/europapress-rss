#!/usr/bin/env python3
"""Persist an already-captured editorial answer even without a chat URL."""
import hashlib
import pathlib
import unittest
from unittest.mock import Mock, patch

import recover_existing_chat_v2 as recovery


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tid = "trv2-301a72a31b33d1e9180c082f"
        self.answer = "Explicación investigada y contrastada para la tendencia. " * 4
        self.record = {"trend_id": self.tid, "revision": 5,
                       "answer": self.answer, "chat_url": "",
                       "lease_token": "owned-lease", "message_sent": True,
                       "reply_captured": True, "cleanup_verified": True,
                       "chat_identity_verified": True, "published": False}

    def test_closed_answer_without_url_is_persisted_not_reasked(self):
        state = Mock()
        digest = hashlib.sha256(self.answer.strip().encode()).hexdigest()
        saved = {"items": {self.tid: {
            "status": "captured_review", "revision": 5,
            "capture": {"sha256": digest, "answer": self.answer.strip(),
                        "chat_url": ""}}}}
        state.stage_capture.return_value = (saved, "staged_pending_editorial_review")
        listas = Mock()
        listas.sync_to_github.return_value = {"items": {self.tid: {"status": "captured_review"}}}
        web = Mock()
        web.sync_to_github.return_value = {"items": [
            {"trend_id": self.tid, "status": "explicada",
             "explanation": self.answer}]}
        def modules(filename, _name):
            if filename == "listas_v2.py": return listas
            if filename == "web_top30_v2.py": return web
            raise AssertionError(filename)
        with (patch.object(recovery.core, "queue_read",
                           side_effect=[({"items": {}}, "sha0"), (saved, "sha1")]),
              patch.object(recovery.core, "queue_write"),
              patch.object(recovery.core, "store"),
              patch.object(recovery.core, "module", side_effect=modules)):
            recovery.persist_existing(object(), "auth", state,
                                      self.record, pathlib.Path("journal.json"))
        self.assertTrue(self.record["persisted"])
        self.assertTrue(state.stage_capture.call_args.kwargs["allow_unlinked_capture"])
        self.assertEqual(state.stage_capture.call_args.kwargs["chat_url"], "")

    def test_missing_url_requires_prior_verified_chat_identity(self):
        journal = pathlib.Path("not-used.json")
        without_identity = {**self.record, "chat_identity_verified": False}
        api = Mock()
        with (patch.object(recovery, "journal_for", return_value=(journal, without_identity)),
              patch.object(recovery, "confirm_remote"),
              patch.object(recovery.core, "module", return_value=api),
              patch.object(recovery, "persist_existing") as persist):
            with self.assertRaisesRegex(RuntimeError, "Diario de recuperación inconsistente"):
                recovery.recover(self.tid, 5, lock_held=True)
        persist.assert_not_called()


if __name__ == "__main__":
    unittest.main()
