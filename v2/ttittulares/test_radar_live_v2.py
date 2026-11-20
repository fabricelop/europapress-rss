"""The radar clock is independent of editorial/image HEAD contention."""
import copy
import json
import unittest
from datetime import timedelta

from .radar_live_v2 import HEALTH_PATH, INDEX_PATH, MASTER_PATH, RADAR_PATH, SUMMARY_PATH, persist_live
from .radar_snapshot_v2 import BRANCH, plan_snapshot
from .radar_store_v2 import RADAR_LIVE_BRANCH, GitHubStore, StoreError
from .test_radar_snapshot_v2 import fixture
from .test_radar_ingest_v2 import BASE
from .test_radar_store_v2 import MemoryStore


class BranchStore(MemoryStore):
    def __init__(self, branch, documents):
        super().__init__(documents)
        self.branch = branch

    def head(self):
        return self.current


class LiveRadarTests(unittest.TestCase):
    def setUp(self):
        self.fetched = fixture()
        initial = plan_snapshot(self.fetched, {}, now=BASE)
        self.editorial = BranchStore(BRANCH, {INDEX_PATH: initial["writes"][INDEX_PATH]})
        self.radar = BranchStore(RADAR_LIVE_BRANCH, {
            RADAR_PATH: copy.deepcopy(initial["writes"][RADAR_PATH]),
            HEALTH_PATH: copy.deepcopy(initial["writes"][HEALTH_PATH]),
        })

    def test_new_scan_persists_only_live_state(self):
        self.editorial.advance({"v2/ttittulares/state/editorial-queue.json": {"concurrent": True}})
        result = persist_live(self.fetched, self.radar, self.editorial, now=BASE + timedelta(minutes=16))
        self.assertTrue(result["verified"])
        self.assertEqual(result["branch"], RADAR_LIVE_BRANCH)
        self.assertEqual(self.radar.write_count, 1)
        self.assertEqual(self.editorial.write_count, 0)
        self.assertEqual(set(self.radar.commits[self.radar.current]), {RADAR_PATH, HEALTH_PATH, SUMMARY_PATH, MASTER_PATH})
        self.assertEqual(self.radar.commits[self.radar.current][RADAR_PATH]["observed_at"], result["observed_at"])
        self.assertEqual(self.radar.commits[self.radar.current][SUMMARY_PATH]["kind"], "independent_radar_summary")
        summary = self.radar.commits[self.radar.current][SUMMARY_PATH]
        self.assertLess(len(json.dumps(summary).encode("utf-8")), 4096)
        self.assertNotIn("items", summary)
        self.assertEqual(summary["observed_at"], result["observed_at"])

    def test_older_scan_does_not_overwrite_newer_radar(self):
        first = persist_live(self.fetched, self.radar, self.editorial, now=BASE + timedelta(minutes=20))
        second = persist_live(self.fetched, self.radar, self.editorial, now=BASE + timedelta(minutes=15))
        self.assertTrue(second["replayed"])
        self.assertEqual(first["observed_at"], second["observed_at"])
        self.assertEqual(self.radar.write_count, 1)

    def test_conflict_on_radar_branch_recomputes(self):
        self.radar.before_commit = lambda branch: branch.advance({HEALTH_PATH: {"changed": True}})
        result = persist_live(self.fetched, self.radar, self.editorial, now=BASE + timedelta(minutes=30))
        self.assertEqual(result["attempts"], 2)
        self.assertEqual(self.radar.write_count, 1)

    def test_no_successful_sources_never_moves_radar(self):
        broken = copy.deepcopy(self.fetched)
        for source in broken["source_statuses"]:
            source["ok"] = False
        with self.assertRaisesRegex(StoreError, "NO_SOURCE_SUCCEEDED"):
            persist_live(broken, self.radar, self.editorial, now=BASE + timedelta(minutes=30))
        self.assertEqual(self.radar.write_count, 0)

    def test_branch_configuration_fails_closed(self):
        with self.assertRaisesRegex(StoreError, "BRANCH_OUTSIDE_V2_SCOPE"):
            GitHubStore("fixture", branch="main")
        with self.assertRaisesRegex(StoreError, "RADAR_LIVE_BRANCH_ISOLATION_REQUIRED"):
            persist_live(self.fetched, self.editorial, self.radar, now=BASE + timedelta(minutes=30))


if __name__ == "__main__":
    unittest.main()
