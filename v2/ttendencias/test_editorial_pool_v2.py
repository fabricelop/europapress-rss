#!/usr/bin/env python3
"""Aislar el cierre de Tendencias: no afectar Imágenes ni Chrome personal."""
import pathlib
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from editorial_pool_v2 import EditorialWorkerPool
from parallel_dispatch_v2 import EPHEMERAL_MARKER


class FakeProcess:
    def __init__(self): self.returncode = None
    def poll(self): return self.returncode


class EditorialPoolTests(unittest.TestCase):
    def make_pool(self, root, count=1):
        seed = pathlib.Path(root) / "ChromeProfile"
        seed.mkdir()
        (seed / "Local State").write_text("authenticated", encoding="utf-8")
        return EditorialWorkerPool(
            seed, count, source_running=lambda: set(),
            env_key="TT_V2_EDITORIAL_PROFILE", logs_dir=pathlib.Path(root)/"logs")

    def test_failed_python_worker_releases_its_own_chrome_and_slot(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_pool(root)
            proc = FakeProcess()
            disk = patch("parallel_dispatch_v2.shutil.disk_usage",
                         return_value=SimpleNamespace(free=20 * 1024**3))
            with (disk, patch("parallel_dispatch_v2.exact_chrome_profile_pids",
                              return_value=set()),
                  patch("parallel_dispatch_v2.subprocess.Popen", return_value=proc)):
                self.assertTrue(pool.spawn(__file__, [], trend_id="t1", revision=1))
            proc.returncode = 1
            present = [{4567}]
            def pids(_profile): return present[0]
            def cleanup(find_pids):
                self.assertEqual(find_pids(), {4567})
                present[0] = set()
                return {"closed": True}
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", side_effect=pids),
                  patch("editorial_pool_v2.exact_chrome_profile_pids", side_effect=pids),
                  patch("editorial_pool_v2.cleanup_v2_profile", side_effect=cleanup)):
                jobs = pool.reap()
                self.assertTrue(jobs[0]["profile_deleted"])
                self.assertEqual(pool.available_slot(), 0)
            self.assertFalse(pool.profiles[0].exists())
            self.assertTrue(pool.seed.exists())

    def test_unclean_chrome_stays_quarantined_and_other_slot_stays_free(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_pool(root, count=2)
            proc = FakeProcess()
            disk = patch("parallel_dispatch_v2.shutil.disk_usage",
                         return_value=SimpleNamespace(free=20 * 1024**3))
            with (disk, patch("parallel_dispatch_v2.exact_chrome_profile_pids",
                              return_value=set()),
                  patch("parallel_dispatch_v2.subprocess.Popen", return_value=proc)):
                self.assertTrue(pool.spawn(__file__, [], trend_id="t1", revision=1))
            proc.returncode = 1
            def pids(profile):
                return {4567} if pathlib.Path(profile) == pool.profiles[0] else set()
            with (patch("parallel_dispatch_v2.exact_chrome_profile_pids", side_effect=pids),
                  patch("editorial_pool_v2.exact_chrome_profile_pids", side_effect=pids),
                  patch("editorial_pool_v2.cleanup_v2_profile", return_value={"closed": False})):
                job = pool.reap()[0]
                self.assertFalse(job["profile_deleted"])
                self.assertTrue((pool.profiles[0] / EPHEMERAL_MARKER).is_file())
                self.assertEqual(pool.available_slot(), 1)
            self.assertTrue(pool.seed.exists())

    def test_unmarked_profile_is_never_terminated_or_deleted(self):
        with tempfile.TemporaryDirectory() as root:
            pool = self.make_pool(root)
            profile = pool.profiles[0]
            profile.mkdir()
            (profile / "user-data").write_text("keep", encoding="utf-8")
            proc = FakeProcess()
            proc.returncode = 1
            pool.active[0] = {"process": proc, "trend_id": "t1",
                              "revision": 1, "slot": 0}
            with patch("editorial_pool_v2.cleanup_v2_profile") as cleanup:
                job = pool.reap()[0]
                self.assertFalse(job["profile_deleted"])
                cleanup.assert_not_called()
            self.assertTrue((profile / "user-data").is_file())


if __name__ == "__main__":
    unittest.main()
