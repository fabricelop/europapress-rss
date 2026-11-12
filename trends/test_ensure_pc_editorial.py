#!/usr/bin/env python3
"""Regression tests: first TTendencias editorial handoff must not await cron."""
import unittest
from datetime import datetime, timedelta, timezone

from trends.ensure_pc_editorial import fresh_queue_first_handoff_allowed


class ImmediateFirstHandoffTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 12, 12, 11, 20, tzinfo=timezone.utc)
        self.rows = [
            {"id": "first", "start": "2026-11-12T12:11:12Z",
             "title": "Tribunal de Cuentas"}
        ]
        self.old_command = {"command_id": "old",
                            "requested_at": "2026-11-12T11:49:22Z"}

    def test_newly_queued_item_is_ready_for_first_handoff(self):
        self.assertTrue(fresh_queue_first_handoff_allowed(
            self.rows, self.old_command, {}, self.now))

    def test_existing_command_for_same_backlog_prevents_duplicate(self):
        command = {"command_id": "already-sent",
                   "requested_at": "2026-11-12T12:11:13Z"}
        self.assertFalse(fresh_queue_first_handoff_allowed(
            self.rows, command, {}, self.now))

    def test_running_editor_prevents_parallel_launch(self):
        run = {"status": "RUNNING",
               "updated_at": "2026-11-12T12:11:14Z"}
        self.assertFalse(fresh_queue_first_handoff_allowed(
            self.rows, self.old_command, run, self.now))

    def test_stale_run_does_not_hold_new_backlog(self):
        run = {"status": "RUNNING",
               "updated_at": "2026-11-12T11:30:00Z"}
        self.assertTrue(fresh_queue_first_handoff_allowed(
            self.rows, self.old_command, run, self.now))

    def test_missing_reliable_start_never_dispatches(self):
        self.assertFalse(fresh_queue_first_handoff_allowed(
            [{"id": "unknown", "start": None}], self.old_command, {}, self.now))


if __name__ == "__main__":
    unittest.main()
