#!/usr/bin/env python3
"""Local pure tests: slots, deduplication, simultaneous jobs, RE selection."""
import pathlib
import os
import tempfile
import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

from parallel_dispatch_v2 import WorkerPool, prepare_profiles
from auto_editorial_policy_v2 import eligible_plan
from chrome_visibility_v2 import V2WindowHider


class FakeProcess:
    def __init__(self):
        self.returncode = None

    def poll(self):
        return self.returncode


class ParallelDispatchTests(unittest.TestCase):
    def test_profiles_are_separate_and_not_overwritten(self):
        with tempfile.TemporaryDirectory() as root:
            base = pathlib.Path(root) / "ChromeProfile"
            base.mkdir()
            (base / "Local State").write_text("auth", encoding="utf-8")
            (base / "Cache").mkdir()
            (base / "Cache" / "unneeded").write_text("cache")
            with self.assertRaisesRegex(RuntimeError, "BASE_CHROME_BUSY"):
                prepare_profiles(base, 3, source_running=lambda: {123})
            profiles = prepare_profiles(base, 3, source_running=lambda: set())
            self.assertEqual(len(set(profiles)), 3)
            self.assertEqual((profiles[1] / "Local State").read_text(), "auth")
            self.assertFalse((profiles[1] / "Cache").exists())
            (profiles[1] / "test").write_text("keep")
            self.assertEqual(profiles, prepare_profiles(base, 3, source_running=lambda: set()))
            self.assertTrue((profiles[1] / "test").exists())

    def test_windows_denied_rename_uses_completed_staging_without_deleting(self):
        with tempfile.TemporaryDirectory() as root:
            base = pathlib.Path(root) / "ChromeProfile"
            base.mkdir()
            (base / "Local State").write_text("session", encoding="utf-8")
            with patch.object(pathlib.Path, "replace", side_effect=PermissionError(5)):
                profiles = prepare_profiles(base, 2, source_running=lambda: set())
            self.assertEqual(profiles[1].name, "ChromeProfile-Parallel-01.building")
            self.assertTrue((profiles[1] / "tt-v2-parallel-ready.marker").is_file())
            self.assertEqual((profiles[1] / "Local State").read_text(), "session")
            self.assertEqual(profiles, prepare_profiles(base, 2, source_running=lambda: set()))

    def test_incomplete_staging_stops_without_reusing_or_deleting(self):
        with tempfile.TemporaryDirectory() as root:
            base = pathlib.Path(root) / "ChromeProfile"
            base.mkdir()
            partial = pathlib.Path(root) / "ChromeProfile-Parallel-01.building"
            partial.mkdir()
            with self.assertRaisesRegex(RuntimeError, "PARTIAL_COPY"):
                prepare_profiles(base, 2, source_running=lambda: set())
            self.assertTrue(partial.exists())

    def test_two_concurrent_jobs_do_not_share_profile_or_duplicate_revision(self):
        with tempfile.TemporaryDirectory() as root:
            base = pathlib.Path(root) / "ChromeProfile"
            base.mkdir()
            profiles = prepare_profiles(base, 2, source_running=lambda: set())
            pool = WorkerPool(profiles, env_key="TT_V2_IMAGE_PROFILE",
                              logs_dir=pathlib.Path(root) / "logs")
            processes, envs = [], []

            def spawn(*args, **kwargs):
                proc = FakeProcess()
                processes.append(proc)
                envs.append(kwargs["env"])
                return proc

            with patch("parallel_dispatch_v2.subprocess.Popen", side_effect=spawn):
                self.assertTrue(pool.spawn(__file__, ["--run"], trend_id="inglaterra",
                                           revision=2, attempt=4))
                self.assertFalse(pool.spawn(__file__, ["--run"], trend_id="inglaterra",
                                            revision=2, attempt=4))
                self.assertTrue(pool.spawn(__file__, ["--run"], trend_id="pedri",
                                           revision=3, attempt=1))
                self.assertIsNone(pool.available_slot())
                self.assertNotEqual(envs[0]["TT_V2_IMAGE_PROFILE"],
                                    envs[1]["TT_V2_IMAGE_PROFILE"])
                processes[0].returncode = 0
                self.assertEqual(pool.reap()[0]["trend_id"], "inglaterra")
                self.assertTrue(pool.spawn(__file__, ["--run"], trend_id="merino",
                                           revision=4, attempt=1))

    def test_review_and_top30_skip_busy_without_global_wait(self):
        now = datetime.now(timezone.utc)
        stamp = now.isoformat()
        items = {
            "review": {"trend_id": "review", "revision": 2,
                       "status": "review_pending", "reason": "user_reexplanation",
                       "attempts": 0, "requested_at": stamp},
            "top": {"trend_id": "top", "revision": 1, "status": "pending",
                    "attempts": 0}
        }
        queue = {"step": "04_editorial_queue", "effects_enabled": False,
                 "source_observed_at": stamp, "items": items}
        history = {"step": "03_movement", "country": "ES", "observed_at": stamp,
                   "topics": {"review": {"trend_id": "review"}}}
        with tempfile.TemporaryDirectory() as root:
            with patch("auto_editorial_policy_v2.select_current_top30",
                       return_value=([items["top"]], 0)):
                first, _, _ = eligible_plan(queue, history, directory=root, now=now)
                second, _, _ = eligible_plan(queue, history, directory=root, now=now,
                                              active_keys={("review", 2)})
                self.assertEqual(first["trend_id"], "review")
                self.assertEqual(second["trend_id"], "top")

    def test_python_workers_request_hidden_windows_startup(self):
        with tempfile.TemporaryDirectory() as root:
            profile = pathlib.Path(root) / "profile"
            profile.mkdir()
            pool = WorkerPool([profile], env_key="TT_V2_EDITORIAL_PROFILE",
                              logs_dir=pathlib.Path(root) / "logs")
            startup = SimpleNamespace(dwFlags=0, wShowWindow=-1)
            with (patch("parallel_dispatch_v2.os", SimpleNamespace(name="nt", environ=os.environ)),
                  patch("parallel_dispatch_v2.subprocess.STARTUPINFO", return_value=startup,
                        create=True),
                  patch("parallel_dispatch_v2.subprocess.STARTF_USESHOWWINDOW", 1, create=True),
                  patch("parallel_dispatch_v2.subprocess.CREATE_NO_WINDOW", 0x08000000,
                        create=True),
                  patch("parallel_dispatch_v2.subprocess.Popen", return_value=FakeProcess()) as popen):
                self.assertTrue(pool.spawn(__file__, [], trend_id="test", revision=1))
                self.assertEqual(startup.wShowWindow, 0)
                self.assertEqual(startup.dwFlags & 1, 1)
                self.assertEqual(popen.call_args.kwargs["creationflags"], 0x08000000)
                self.assertIs(popen.call_args.kwargs["startupinfo"], startup)

    def test_hidden_chrome_refuses_visible_windows(self):
        hider = V2WindowHider(lambda: {434343}, primary_pid=434343)
        with (patch("chrome_visibility_v2.hide_windows_for_pids") as hide,
              patch("chrome_visibility_v2.visible_windows_for_pids", return_value=0)):
            hider.ensure_hidden()
            hide.assert_called_once_with({434343})
        with (patch("chrome_visibility_v2.hide_windows_for_pids"),
              patch("chrome_visibility_v2.visible_windows_for_pids", return_value=1)):
            with self.assertRaisesRegex(RuntimeError, "WINDOW_VISIBLE"):
                hider.ensure_hidden()


if __name__ == "__main__":
    unittest.main()
