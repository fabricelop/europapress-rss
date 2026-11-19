"""A temporary GitHub rate limit pauses sends; forbidden auth is not bypassed."""
import email.message
import base64
import hashlib
import io
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
import urllib.error
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
os.environ.setdefault("LOCALAPPDATA", tempfile.gettempdir())
import editorial_github_access_v2 as github
import editorial_run_v2 as editorial


class GithubAccessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cooldown = pathlib.Path(self.tmp.name) / "github-rate-limit.json"
        p = patch.object(github, "COOLDOWN", self.cooldown)
        p.start()
        self.addCleanup(p.stop)

    @staticmethod
    def rejected(status, *, body, headers=None):
        h = email.message.Message()
        for name, value in (headers or {}).items():
            h[name] = value
        return urllib.error.HTTPError(github.API, status, "blocked", h,
                                     io.BytesIO(json.dumps({"message": body}).encode()))

    def test_rate_limit_403_creates_shared_cooldown_and_prevents_hammering(self):
        error = self.rejected(403, body="API rate limit exceeded",
                              headers={"X-RateLimit-Remaining": "0",
                                       "X-RateLimit-Reset": str(int(time.time()) + 200)})
        with patch.object(github.urllib.request, "urlopen", side_effect=error) as network:
            with self.assertRaisesRegex(RuntimeError, "GITHUB_RATE_LIMIT_PAUSED"):
                github.request("GET", "fake-test-token")
            with self.assertRaisesRegex(RuntimeError, "GITHUB_RATE_LIMIT_PAUSED"):
                github.request("GET", "fake-test-token")
        network.assert_called_once()
        self.assertGreater(json.loads(self.cooldown.read_text())["until"], time.time() + 60)

    def test_secondary_limit_403_with_available_primary_quota_pauses(self):
        error = self.rejected(403, body="You have exceeded a secondary rate limit.",
                              headers={"X-RateLimit-Remaining": "4200", "Retry-After": "120"})
        with patch.object(github.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "retry_in_seconds=120"):
                github.request("GET", "fake-test-token")

    def test_permission_403_does_not_create_cooldown_or_switch_credentials(self):
        error = self.rejected(403, body="Resource not accessible by integration")
        with patch.object(github.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "GITHUB_FORBIDDEN_AUTH_OR_POLICY"):
                github.request("GET", "fake-test-token")
        self.assertFalse(self.cooldown.exists())

    def test_expired_pause_permits_normal_authenticated_request(self):
        self.cooldown.write_text(json.dumps({"until": 1}))
        response = io.BytesIO(b'{"sha":"expected"}')
        response.__enter__ = lambda s: s
        response.__exit__ = lambda s, *args: None
        with patch.object(github.urllib.request, "urlopen", return_value=response):
            self.assertEqual(github.request("GET", "fake-test-token")["sha"], "expected")

    def test_large_queue_blob_get_obeys_the_same_rate_pause(self):
        error = self.rejected(403, body="You have exceeded a secondary rate limit")
        with patch.object(github.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "GITHUB_RATE_LIMIT_PAUSED"):
                github.blob_request("a" * 40, "fake-test-token")
        self.assertTrue(self.cooldown.exists())

    def test_large_queue_is_read_by_authenticated_blob_with_sha_verification(self):
        state = {"step": "04_editorial_queue", "effects_enabled": False, "items": {}}
        raw = json.dumps(state).encode()
        sha = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        api = Mock()
        api.request.return_value = {"content": "", "encoding": "none", "sha": sha}
        api.blob_request.return_value = {"encoding": "base64",
                                         "content": base64.b64encode(raw).decode()}
        parsed, blob_sha = editorial.queue_read(api, "fake-test-token")
        self.assertEqual(parsed, state)
        self.assertEqual(blob_sha, sha)
        api.blob_request.assert_called_once_with(sha, "fake-test-token")

    def test_installer_stages_editorial_only_and_accepts_fixed_commit(self):
        text = (pathlib.Path(__file__).with_name("Activate-V2-Editorial-Cycle.ps1")
                .read_text(encoding="utf-8"))
        self.assertIn("if ($CommitSha)", text)
        self.assertIn("'Activate-V2-Editorial-Cycle.ps1')", text)
        self.assertIn("'editorial_github_access_v2.py'", text)
        self.assertIn("'auto_editorial_policy_v2.py'", text)
        self.assertIn("$newPolicy.Contains('ranked.sort(key=')", text)
        self.assertIn("'chrome_visibility_v2.py'", text)
        self.assertIn("'test_editorial_orphan_recovery_v2.py'", text)
        self.assertNotIn("'persist_capture_github.py',", text)
        self.assertIn("$newDaemon.Contains('recover_orphaned_attempt')", text)


if __name__ == "__main__":
    unittest.main()
