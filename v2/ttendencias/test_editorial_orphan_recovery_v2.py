"""An exhausted 403 must not leave a finished editorial lease stranded."""
import json
import os
import pathlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
os.environ.setdefault("LOCALAPPDATA", tempfile.gettempdir())
import editorial_daemon_v2 as daemon


class OrphanRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = pathlib.Path(self.temp.name)
        self.now = datetime(2026, 11, 19, 13, 10, tzinfo=timezone.utc)
        self.row = {"trend_id": "trv2-example", "name": "Example", "revision": 6,
                    "status": "in_progress", "lease": {"token": "lease-abc",
                    "started_at": (self.now - timedelta(minutes=21)).isoformat()}}
        self.queue = {"source_observed_at": "2026-11-19T13:00:00Z",
                      "items": {"trv2-example": self.row}}
        self.history = {"step": "03_movement", "observed_at": "2026-11-19T13:00:00Z",
                        "top30": ["Example"], "topics": {"Example": {
                            "name": "Example", "active": True, "trend_id": "trv2-example"}}}
        self.evidence = {"trend_id": "trv2-example", "revision": 6,
                         "lease_token": "lease-abc", "message_sent": False,
                         "reply_captured": False, "cleanup_verified": True}
        self.journal = self.directory / "run-trv2-example-r6.json"
        self.journal.write_text(json.dumps(self.evidence))

    def test_old_claim_with_matching_journal_is_recoverable_before_remote_40min(self):
        found = daemon.orphaned_attempts(self.queue, self.history,
                                         directory=self.directory, now=self.now)
        self.assertEqual(found, [("trv2-example", 6, self.evidence)])

    def test_recent_claim_is_not_reset_while_chat_might_still_be_running(self):
        self.row["lease"]["started_at"] = (self.now - timedelta(minutes=19)).isoformat()
        self.assertEqual(daemon.orphaned_attempts(self.queue, self.history,
                         directory=self.directory, now=self.now), [])

    def test_wrong_token_or_missing_journal_is_not_reset(self):
        self.evidence["lease_token"] = "different"
        self.journal.write_text(json.dumps(self.evidence))
        self.assertEqual(daemon.orphaned_attempts(self.queue, self.history,
                         directory=self.directory, now=self.now), [])
        self.journal.unlink()
        self.assertEqual(daemon.orphaned_attempts(self.queue, self.history,
                         directory=self.directory, now=self.now), [])

    def test_reconciliation_checks_no_owned_chrome_before_mutating_queue(self):
        incident = Mock()
        with (patch.object(daemon.core, "queue_read", return_value=(self.queue, "sha")),
              patch.object(daemon, "read_history", return_value=self.history),
              patch.object(daemon, "orphaned_attempts", return_value=[
                  ("trv2-example", 6, self.evidence)]),
              patch.object(daemon.core, "module", return_value=incident),
              patch.object(daemon, "settle_failed_job", return_value="new_revision") as settle):
            self.assertEqual(daemon.recover_orphaned_attempt(Mock(), "auth"),
                             "new_revision")
            incident.ensure_no_owned_chrome.assert_called_once_with()
            settle.assert_called_once()

    def test_live_orphaned_chrome_blocks_any_reset(self):
        incident = Mock()
        incident.ensure_no_owned_chrome.side_effect = RuntimeError("CHROME_BUSY")
        with (patch.object(daemon.core, "queue_read", return_value=(self.queue, "sha")),
              patch.object(daemon, "read_history", return_value=self.history),
              patch.object(daemon, "orphaned_attempts", return_value=[
                  ("trv2-example", 6, self.evidence)]),
              patch.object(daemon.core, "module", return_value=incident),
              patch.object(daemon, "settle_failed_job") as settle):
            with self.assertRaisesRegex(RuntimeError, "CHROME_BUSY"):
                daemon.recover_orphaned_attempt(Mock(), "auth")
            settle.assert_not_called()


if __name__ == "__main__":
    unittest.main()
