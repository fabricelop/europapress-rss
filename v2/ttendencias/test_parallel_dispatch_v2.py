#!/usr/bin/env python3
"""Local pure tests: slots, deduplication, simultaneous jobs, RE selection."""
import pathlib
import os
import tempfile
import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch

from parallel_dispatch_v2 import (
    DisposableWorkerPool, EPHEMERAL_MARKER, WorkerPool, prepare_profiles,
)
from auto_editorial_policy_v2 import eligible_plan
from chrome_visibility_v2 import V2WindowHider


class FakeProcess:
    def __init__(self):
        self.returncode = None

    def poll(self):
        return self.returncode

    def terminate(self):
        self.returncode = -15

    def wait(self, timeout=None):
        return self.returncode


class ParallelDispatchTests(unittest.TestCase):
    def setUp(self):
        # CI runners may have <8 GiB free. Test the policy with a controlled
        # disk budget; the low-space case overrides this fixture explicitly.
        disk = patch("parallel_dispatch_v2.shutil.disk_usage",
                     return_value=SimpleNamespace(free=20 * 1024 ** 3))
        disk.start()
        self.addCleanup(disk.stop)

    def make_disposable_pool(self, root, *, count=2):
        seed = pathlib.Path(root) / "ChromeProfile"
        seed.mkdir()
        (seed / "Local State").write_text("authenticated", encoding="utf-8")
        return DisposableWorkerPool(seed, count, source_running=lambda: set(),
                                    env_key="TT_V2_EDITORIAL_PROFILE",
                                    logs_dir=pathlib.Path(root) / "logs")

    def test_both_automatic_consumers_use_disposable_profiles(self):
        directory = pathlib.Path(__file__).parent
        for script in ("editorial_daemon_v2.py", "image_daemon_v2.py"):
            content = (directory / script).read_text(encoding="utf-8")
            self.assertIn("pool = DisposableWorkerPool(", content)
            self.assertNotIn("pool = WorkerPool(", content)

    def test_disposable_jobs_clone_seed_then_delete_after_worker_exits(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_disposable_pool(root)
            self.assertTrue(all(not path.exists() for path in pool.profiles))
            procs, launched = [], []

            def start(*args, **kwargs):
                proc = FakeProcess()
                procs.append(proc)
                launched.append(kwargs["env"]["TT_V2_EDITORIAL_PROFILE"])
                return proc

            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value=set()),
                  patch("parallel_dispatch_v2.subprocess.Popen", side_effect=start)):
                self.assertTrue(pool.spawn(__file__, [], trend_id="one", revision=1))
                first = pool.profiles[0]
                self.assertTrue((first / EPHEMERAL_MARKER).is_file())
                self.assertEqual((first / "Local State").read_text(), "authenticated")
                (first / "browser-cache").write_text("throwaway")
                self.assertTrue(pool.spawn(__file__, [], trend_id="two", revision=1))
                self.assertNotEqual(launched[0], launched[1])
                procs[0].returncode = 1  # Failed chat must be disposable too.
                done = pool.reap()
                self.assertEqual(done[0]["profile_deleted"], True)
                self.assertFalse(first.exists())
                self.assertTrue(pool.spawn(__file__, [], trend_id="three", revision=2))
                self.assertFalse((first / "browser-cache").exists())
                procs[1].returncode = 0
                procs[2].returncode = 0
                self.assertTrue(all(job["profile_deleted"] for job in pool.reap()))
                self.assertTrue(all(not profile.exists() for profile in pool.profiles))
                self.assertTrue(pool.seed.is_dir())

    def test_disposable_profile_in_use_is_preserved_and_blocks_next_job(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_disposable_pool(root, count=1)
            proc = FakeProcess()
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value=set()),
                  patch("parallel_dispatch_v2.subprocess.Popen", return_value=proc)):
                self.assertTrue(pool.spawn(__file__, [], trend_id="one", revision=1))
            proc.returncode = 0
            with patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value={7456}):
                done = pool.reap()
                self.assertFalse(done[0]["profile_deleted"])
                self.assertIn("CHROME_STILL_RUNNING", done[0]["profile_cleanup_error"])
                self.assertIsNone(pool.available_slot())
                self.assertFalse(pool.spawn(__file__, [], trend_id="two", revision=1))
            self.assertTrue(pool.profiles[0].exists())
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value=set()),
                  patch("parallel_dispatch_v2.subprocess.Popen", return_value=FakeProcess())):
                self.assertTrue(pool.spawn(__file__, [], trend_id="two", revision=1))
            self.assertTrue(pool.seed.exists())

    def test_orphaned_slot_does_not_block_another_free_slot(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_disposable_pool(root, count=2)
            first_process = FakeProcess()
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value=set()),
                  patch("parallel_dispatch_v2.subprocess.Popen", return_value=first_process)):
                self.assertTrue(pool.spawn(__file__, [], trend_id="one", revision=1))
            first_process.returncode = 1
            def pids(profile):
                return {7456} if pathlib.Path(profile) == pool.profiles[0] else set()
            with patch("parallel_dispatch_v2.exact_chrome_profile_pids", side_effect=pids):
                done = pool.reap()
                self.assertFalse(done[0]["profile_deleted"])
                self.assertEqual(pool.available_slot(), 1)
                with patch("parallel_dispatch_v2.subprocess.Popen", return_value=FakeProcess()):
                    self.assertTrue(pool.spawn(__file__, [], trend_id="two", revision=1))
                self.assertIn(1, pool.active)
                self.assertEqual(pool.active[1]["trend_id"], "two")

    def test_disposable_refuses_unmarked_profile_and_low_disk(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_disposable_pool(root, count=1)
            slot = pool.profiles[0]
            slot.mkdir()
            (slot / "possibly-user-data").write_text("keep")
            with self.assertRaisesRegex(RuntimeError, "OWNERSHIP_UNVERIFIED"):
                pool.spawn(__file__, [], trend_id="one", revision=1)
            self.assertTrue((slot / "possibly-user-data").exists())
            # Only test the free-space guard after removing our test fixture.
            (slot / "possibly-user-data").unlink()
            slot.rmdir()
            with patch("parallel_dispatch_v2.shutil.disk_usage",
                       return_value=SimpleNamespace(free=5 * 1024 ** 3)):
                with self.assertRaisesRegex(RuntimeError, "DISK_SPACE_LOW"):
                    pool.spawn(__file__, [], trend_id="one", revision=1)
            self.assertFalse(slot.exists())

    def test_session_watchdog_closes_only_owned_slot_after_eight_minutes(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_disposable_pool(root, count=1)
            now = [100.0]
            pool.clock = lambda: now[0]
            proc = FakeProcess()
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value=set()),
                  patch("parallel_dispatch_v2.subprocess.Popen", return_value=proc),
                  patch("parallel_dispatch_v2.cleanup_v2_profile", return_value={"closed": True}) as cleanup):
                self.assertTrue(pool.spawn(__file__, [], trend_id="slow", revision=1))
                now[0] = 579.0
                self.assertEqual(pool.reap(), [])
                self.assertIsNone(proc.returncode)
                now[0] = 580.0
                finished = pool.reap()
                self.assertEqual(len(finished), 1)
                self.assertTrue(finished[0]["timed_out"])
                self.assertEqual(finished[0]["exit_code"], 124)
                self.assertTrue(finished[0]["profile_deleted"])
                cleanup.assert_called_once()
                self.assertTrue(pool.seed.exists())
                self.assertFalse(pool.profiles[0].exists())

    def test_disposable_cleans_partial_copy_and_failed_worker_launch(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_disposable_pool(root, count=1)
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value=set()),
                  patch("parallel_dispatch_v2.shutil.copytree", side_effect=OSError("disk full"))):
                with self.assertRaisesRegex(OSError, "disk full"):
                    pool.spawn(__file__, [], trend_id="one", revision=1)
            self.assertFalse(pool.profiles[0].exists())
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value=set()),
                  patch("parallel_dispatch_v2.subprocess.Popen", side_effect=OSError("no process"))):
                with self.assertRaisesRegex(OSError, "no process"):
                    pool.spawn(__file__, [], trend_id="two", revision=1)
            self.assertFalse(pool.profiles[0].exists())

    def test_disposable_cleans_owned_empty_slot_when_marker_write_fails(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_disposable_pool(root, count=1)
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", return_value=set()),
                  patch("parallel_dispatch_v2.pathlib.Path.write_text",
                        side_effect=OSError("disk full"))):
                with self.assertRaisesRegex(OSError, "disk full"):
                    pool.spawn(__file__, [], trend_id="one", revision=1)
            self.assertFalse(pool.profiles[0].exists())

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
