"""One-shot editorial pilots cannot silently open a second ChatGPT chat."""

import contextlib
import io
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
os.environ.setdefault("LOCALAPPDATA", tempfile.gettempdir())
import editorial_daemon_v2 as daemon
import editorial_run_v2 as editorial
import web_top30_v2 as web_top30


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
        self.assertTrue("'Install-V2-Editorial-Auto.ps1'" in installer,
                        "installer must update its local copy before tests")
        self.assertTrue("'image_daemon_v2.py'" in installer,
                        "installer must update the image daemon before tests")
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


class PostPersistProjectionTests(unittest.TestCase):
    def test_json_error_defers_web_sync_without_invalidating_capture(self):
        sync = Mock()
        sync.sync_to_github.side_effect = RuntimeError(
            'Top30 web no sincronizado: Expecting value: line 1 column 1 (char 0)')
        output = io.StringIO()
        with (patch.object(editorial, 'module', return_value=sync),
              contextlib.redirect_stdout(output)):
            self.assertFalse(editorial.refresh_web_after_persist('auth', 'id', 1, 'answer'))
        self.assertIn('TT_V2_WEB_TOP30_DEFERRED=RuntimeError', output.getvalue())
        sync.sync_to_github.assert_called_once_with('auth')

    def test_verified_web_snapshot_remains_checked(self):
        sync = Mock()
        sync.sync_to_github.return_value = {'items': [
            {'trend_id': 'id', 'revision': 1, 'status': 'explicada',
             'explanation': 'answer'}]}
        with patch.object(editorial, 'module', return_value=sync):
            self.assertTrue(editorial.refresh_web_after_persist('auth', 'id', 1, 'answer'))
            self.assertFalse(editorial.refresh_web_after_persist('auth', 'id', 2, 'answer'))

    def test_idle_web_retry_never_opens_editorial_chat(self):
        sync = Mock()
        sync.sync_to_github.side_effect = [RuntimeError('GitHub transient'), {'items': []}]
        with patch.object(daemon.core, 'module', return_value=sync):
            self.assertFalse(daemon.retry_web_projection('auth'))
            self.assertTrue(daemon.retry_web_projection('auth'))
        self.assertEqual(sync.sync_to_github.call_count, 2)

    def test_non_json_github_api_response_reports_metadata_only(self):
        response = Mock()
        response.read.return_value = b'<html>not-json</html>'
        response.headers.get.return_value = 'text/html'
        response.status = 200
        context = MagicMock()
        context.__enter__.return_value = response
        with patch.object(web_top30.urllib.request, 'urlopen', return_value=context):
            with self.assertRaisesRegex(RuntimeError, 'invalid_json.*bytes=21'):
                web_top30.gh('GET', 'fake-auth', 'web-top30.json')


if __name__ == "__main__":
    unittest.main()
