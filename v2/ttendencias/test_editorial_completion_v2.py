"""Failed chats must leave the Top30 scheduler able to choose a fresh job."""
import json
import contextlib
import pathlib
import tempfile
import unittest
from unittest.mock import Mock, patch

import editorial_daemon_v2 as daemon
from test_incident_retry_v2 import sample


class EditorialCompletionTests(unittest.TestCase):
    def setUp(self):
        self.queue, _ = sample()
        self.ident = next(iter(self.queue["items"]))
        self.row = self.queue["items"][self.ident]
        self.row.update(status="in_progress", attempts=1,
                        lease={"token": "old-lease", "started_at": "2026-11-19T10:30:00Z",
                               "expires_at": "2026-11-19T11:10:00Z"})
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name)
        self.writes = []
        self.journal = {"trend_id": self.ident, "revision": 1,
                        "lease_token": "old-lease", "message_sent": False,
                        "reply_captured": False}
        self.save_journal()

    def save_journal(self):
        file = self.path / ("run-" + self.ident + "-r1.json")
        file.write_text(json.dumps(self.journal), encoding="utf-8")

    def settle(self, *, cleaned=True, reason="worker_exit_1"):
        def write(api, auth, sha, queue, description):
            self.writes.append(queue)
        with (patch.object(daemon.core, "DIAG_DIR", self.path),
              patch.object(daemon.core, "queue_read",
                           return_value=(self.queue, "old-blob-sha")),
              patch.object(daemon.core, "queue_write", side_effect=write)):
            outcome = daemon.settle_failed_job(
                object(), "auth", self.ident, 1,
                cleanup_verified=cleaned, failure_reason=reason)
        return outcome, self.writes[-1] if self.writes else None

    def test_clean_failure_immediately_frees_old_revision(self):
        outcome, queue = self.settle()
        self.assertEqual(outcome, "new_revision")
        row = queue["items"][self.ident]
        self.assertEqual(row["revision"], 2)
        self.assertEqual(row["status"], "pending")
        self.assertEqual(row["attempts"], 0)
        self.assertEqual(row["incident_retries"], 1)
        self.assertNotIn("lease", row)
        self.assertIn(self.ident, queue["pending_ids"])
        self.assertEqual(row["previous_attempts"][-1]["incident_reason"],
                         "worker_exit_1")

    def test_previous_send_is_archived_not_sent_again_in_same_revision(self):
        self.row["send_intent"] = {"token": "old-lease",
                                   "at": "2026-11-19T10:33:00Z"}
        self.journal["message_sent"] = True
        self.save_journal()
        outcome, queue = self.settle(reason="session_8min_timeout")
        self.assertEqual(outcome, "new_revision")
        row = queue["items"][self.ident]
        self.assertNotIn("send_intent", row)
        self.assertEqual(row["previous_attempts"][-1]["send_intent_at"],
                         "2026-11-19T10:33:00Z")

    def test_failure_stage_is_recorded_without_leaking_exception_details(self):
        self.journal["error"] = "ChatGPT no está listo; no enviar"
        self.save_journal()
        outcome, queue = self.settle()
        self.assertEqual(outcome, "new_revision")
        self.assertEqual(queue["items"][self.ident]["previous_attempts"][-1]
                         ["incident_reason"], "chat_not_ready")
        self.assertNotIn("no enviar", str(queue))

    def test_uncertain_chrome_cleanup_quarantines_but_releases_lease(self):
        outcome, queue = self.settle(cleaned=False)
        self.assertEqual(outcome, "quarantined")
        row = queue["items"][self.ident]
        self.assertEqual(row["revision"], 1)
        self.assertEqual(row["status"], "capture_recovery")
        self.assertEqual(row["capture_recovery_reason"],
                         "session_cleanup_unverified")
        self.assertNotIn("lease", row)

    def test_local_answer_is_preserved_for_recovery_not_reasked(self):
        self.journal["reply_captured"] = True
        self.save_journal()
        outcome, queue = self.settle()
        self.assertEqual(outcome, "quarantined")
        self.assertEqual(queue["items"][self.ident]["revision"], 1)
        self.assertEqual(queue["items"][self.ident]["capture_recovery_reason"],
                         "captured_locally_needs_persist")

    def test_missing_or_mismatched_journal_does_not_reask(self):
        self.journal["lease_token"] = "different"
        self.save_journal()
        outcome, queue = self.settle()
        self.assertEqual(outcome, "lease_changed")
        self.assertIsNone(queue)
        self.journal["lease_token"] = ""
        self.save_journal()
        outcome, queue = self.settle()
        self.assertEqual(outcome, "quarantined")
        self.assertEqual(queue["items"][self.ident]["capture_recovery_reason"],
                         "session_journal_unverified")

    def test_retry_budget_finite(self):
        self.row["incident_retries"] = 2
        outcome, queue = self.settle()
        self.assertEqual(outcome, "quarantined")
        self.assertEqual(queue["items"][self.ident]["revision"], 1)
        self.assertEqual(queue["items"][self.ident]["capture_recovery_reason"],
                         "automatic_retry_limit_reached")

    def test_confirmed_capture_wins_over_late_child_failure(self):
        self.row["status"] = "captured_review"
        self.row["capture"] = {"verified_complete": True}
        outcome, queue = self.settle()
        self.assertEqual(outcome, "already_captured")
        self.assertIsNone(queue)


class WavePool:
    def __init__(self, workers):
        self.workers = workers
        self.active = {}
        self.spawned = []
        self.drained = False

    @property
    def busy_keys(self):
        return {(data[0], data[1]) for data in self.active.values()}

    def available_slot(self):
        return next((n for n in range(self.workers) if n not in self.active), None)

    def spawn(self, script, args, *, trend_id, revision):
        slot = self.available_slot()
        self.spawned.append((trend_id, revision, len(self.active)))
        self.active[slot] = (trend_id, revision)
        return True

    def reap(self):
        if not self.active:
            return []
        slot = next(iter(self.active))
        trend_id, revision = self.active.pop(slot)
        return [{"trend_id": trend_id, "revision": revision,
                 "exit_code": 1, "profile_deleted": True, "log": "mock.log"}]

    def wait_for_completion(self):
        self.drained = True
        events = []
        while self.active:
            events.extend(self.reap())
        return events


class EditorialWavesTests(unittest.TestCase):
    def run_daemon(self, pool, *, max_jobs, selected, enabled):
        api = Mock()
        api.token.return_value = "test-auth"
        api.process_one.return_value = False
        with (patch.object(daemon, "flag_is_enabled", side_effect=enabled),
              patch.object(daemon, "exclusive_v2_lock",
                           return_value=contextlib.nullcontext()),
              patch.object(daemon, "DisposableWorkerPool", return_value=pool),
              patch.object(daemon, "check", side_effect=selected),
              patch.object(daemon, "settle_failed_job",
                           return_value="new_revision") as settle,
              patch.object(daemon, "report"),
              patch.object(daemon.time, "sleep"),
              patch.object(daemon.core, "module", return_value=api)):
            daemon.run_forever(poll_seconds=90, max_jobs=max_jobs,
                               workers=pool.workers)
        return settle

    def test_wave_drains_before_starting_next_trend(self):
        pool = WavePool(workers=3)
        targets = [({"trend_id": "topic%d" % n, "revision": 1}, 1, [])
                   for n in range(1, 5)]
        settled = self.run_daemon(pool, max_jobs=4,
                                  selected=targets, enabled=[True] * 20)
        self.assertEqual([x[0] for x in pool.spawned],
                         ["topic1", "topic2", "topic3", "topic4"])
        self.assertEqual([x[2] for x in pool.spawned], [0, 1, 2, 0])
        self.assertEqual(settled.call_count, 4)

    def test_cooperative_shutdown_settles_last_finished_chat(self):
        pool = WavePool(workers=1)
        selected = [({"trend_id": "last", "revision": 1}, 1, [])]
        settled = self.run_daemon(pool, max_jobs=0, selected=selected,
                                  enabled=[True, True, False])
        self.assertTrue(pool.drained)
        self.assertEqual(settled.call_count, 1)
        self.assertEqual(settled.call_args.args[2:4], ("last", 1))


if __name__ == "__main__":
    unittest.main()
