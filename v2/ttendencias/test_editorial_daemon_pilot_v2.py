"""One-shot editorial pilots cannot silently open a second ChatGPT chat."""

import contextlib
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
os.environ.setdefault("LOCALAPPDATA", tempfile.gettempdir())
import editorial_daemon_v2 as daemon


class FakePool:
    def __init__(self):
        self.active = {}
        self.spawned = []
        self.reaped_once = False

    @property
    def busy_keys(self):
        return set()

    def available_slot(self):
        return None if self.active else 0

    def spawn(self, script, args, *, trend_id, revision):
        self.spawned.append((trend_id, revision))
        self.active[0] = True
        return True

    def reap(self):
        if self.active and not self.reaped_once:
            self.reaped_once = True
            self.active.clear()
            return [{"trend_id": "test-topic", "revision": 1,
                     "exit_code": 1, "log": "failed.log"}]
        return []

    def wait_for_completion(self):
        raise AssertionError("one-shot test must drain before exiting")


class OneShotPilotTests(unittest.TestCase):
    def test_pilot_installation_avoids_recovering_legacy_chats(self):
        installer = (pathlib.Path(__file__).resolve().parent /
                     "Install-V2-Editorial-Auto.ps1").read_text(encoding="utf-8")
        self.assertIn("'image_daemon_v2.py'", installer)
        self.assertLess(installer.index("if ($PilotOnly) {"),
                        installer.index("$recover = Join-Path"))
        self.assertLess(installer.index("if ($PilotOnly) {"),
                        installer.index("$headless = Join-Path"))
        self.assertIn("TT_V2_PILOT_INSTALL_OPENED_CHROME=NO", installer)

    def _run(self, eligible):
        pool = FakePool()
        api = Mock()
        api.token.return_value = "test-auth"
        selection = ({"trend_id": "test-topic", "revision": 1}, 1, []) if eligible else (None, 1, [])
        with (patch.object(daemon, "flag_is_enabled", return_value=True),
              patch.object(daemon, "exclusive_v2_lock", return_value=contextlib.nullcontext()),
              patch.object(daemon, "DisposableWorkerPool", return_value=pool),
              patch.object(daemon, "check", return_value=selection) as check,
              patch.object(daemon, "report"),
              patch.object(daemon.time, "sleep"),
              patch.object(daemon.core, "module", return_value=api) as module):
            daemon.run_forever(poll_seconds=90, max_jobs=1, workers=1)
        return pool, check, module

    def test_failed_chat_counts_as_the_only_attempt(self):
        pool, check, module = self._run(eligible=True)
        self.assertEqual(pool.spawned, [("test-topic", 1)])
        self.assertEqual(check.call_count, 1)
        self.assertEqual(module.call_count, 1)

    def test_no_eligible_chat_exits_without_incident_recovery(self):
        pool, check, module = self._run(eligible=False)
        self.assertEqual(pool.spawned, [])
        self.assertEqual(check.call_count, 1)
        self.assertEqual(module.call_count, 1)


if __name__ == "__main__":
    unittest.main()
