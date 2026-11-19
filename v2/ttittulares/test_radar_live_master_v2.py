"""Atomic radar/master publication contract without external services."""
import copy
import unittest
from datetime import datetime, timezone
from unittest.mock import patch

from .radar_live_v2 import persist_live, MASTER_PATH, RADAR_PATH, INDEX_PATH, SUMMARY_PATH
from .radar_snapshot_v2 import BRANCH
from .radar_store_v2 import RADAR_LIVE_BRANCH, allowed_write


class _Store:
    def __init__(self, branch, documents):
        self.branch, self.documents = branch, copy.deepcopy(documents)
        self.commits = []

    def head(self):
        return "a" * 40

    def read_documents(self, head, paths):
        return {path: copy.deepcopy(self.documents[path]) for path in paths}

    def commit(self, head, writes, message):
        self.commits.append(copy.deepcopy(writes))
        self.documents.update(copy.deepcopy(writes))
        return "b" * 40


class RadarMasterTests(unittest.TestCase):
    def test_new_path_is_allowed_but_no_chat_job_is_emitted(self):
        self.assertTrue(allowed_write(MASTER_PATH))
        self.assertFalse(allowed_write("v2/ttittulares/jobs/editorial/any.json"))
        now = datetime(2026, 11, 19, 17, tzinfo=timezone.utc)
        radar = _Store(RADAR_LIVE_BRANCH,
                       {RADAR_PATH: {"project": "ttittulares-v2", "items": {}}})
        editorial = _Store(BRANCH,
                           {INDEX_PATH: {"project": "ttittulares-v2", "items": {}}})
        plan = {"radar_state": {"project": "ttittulares-v2", "items": {},
                                "observed_at": "2026-11-19T17:00:00Z",
                                "source_health": {}, "metrics": {"eligible_count": 0}},
                "newly_eligible": [], "material_updates_eligible": []}
        with patch("v2.ttittulares.radar_live_v2.ingest_scan", return_value=plan):
            output = persist_live({"rows": [], "source_statuses": [{"ok": True}]},
                                  radar, editorial, now=now)
        self.assertTrue(output["verified"])
        self.assertEqual(output["new_job_count"], 0)
        self.assertEqual(radar.documents[MASTER_PATH]["items"], [])
        self.assertEqual(radar.documents[SUMMARY_PATH]["master_news_count"], 0)
        self.assertFalse(any("jobs/editorial" in path for path in radar.commits[0]))


if __name__ == "__main__":
    unittest.main()
