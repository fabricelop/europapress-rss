"""Lossless archive and active-news parity checks; no network or production writes."""
import copy
import unittest
from datetime import timedelta

from .master_news_v2 import project_master_news
from .radar_archive_v2 import archive_expired_events, restore_archive, ARCHIVE_PREFIX, MAX_BATCH_ITEMS
from .radar_ingest_v2 import ingest_scan
from .radar_live_v2 import INDEX_PATH, MASTER_PATH, RADAR_PATH, persist_live
from .radar_snapshot_v2 import BRANCH, sha256
from .radar_store_v2 import RADAR_LIVE_BRANCH, StoreError, allowed_write
from .test_radar_ingest_v2 import BASE, GENERAL, make_row, run, statuses
from .test_radar_live_v2 import BranchStore
from .test_radar_snapshot_v2 import fixture


def expired_fixture():
    row = make_row(GENERAL[0], suffix="archived-2026")
    first = run([row], at=BASE)["radar_state"]
    expired = run([], previous=first, at=BASE + timedelta(hours=25))["radar_state"]
    event_id = next(iter(expired["items"]))
    assert expired["items"][event_id]["status"] == "archived"
    return row, event_id, expired


class ArchivingTests(unittest.TestCase):
    def test_expired_events_move_without_loss_and_block_reingestion(self):
        row, event_id, old = expired_fixture()
        baseline = copy.deepcopy(old)
        now = BASE + timedelta(days=4)
        compact, archive_path, document = archive_expired_events(old, now=now)
        self.assertEqual(old, baseline, "pure planner cannot mutate the original")
        self.assertTrue(allowed_write(archive_path))
        self.assertTrue(archive_path.startswith(ARCHIVE_PREFIX))
        self.assertEqual(restore_archive(document)[event_id], old["items"][event_id])
        self.assertEqual(document["encoding"], "gzip+base64")
        damaged = copy.deepcopy(document)
        damaged["payload_sha256"] = "0"*64
        with self.assertRaisesRegex(ValueError,"RADAR_ARCHIVE_CORRUPTED"):
            restore_archive(damaged)
        self.assertNotIn(event_id, compact["items"])
        self.assertIn(event_id, compact["archive_index"])
        self.assertEqual(compact["metrics"]["candidate_count"], old["metrics"]["candidate_count"])
        self.assertEqual(compact["metrics"]["archived_count"], old["metrics"]["archived_count"])
        self.assertEqual(compact["archive_manifest"][0]["sha256"], sha256(document))

        repeated = run([row], previous=compact, at=now + timedelta(minutes=15))
        self.assertNotIn(event_id, repeated["radar_state"]["items"])
        self.assertEqual(repeated["radar_state"]["metrics"]["candidate_count"], 1)
        self.assertEqual(len(repeated["radar_state"]["archive_index"]), 1)
        after, next_path, next_doc = archive_expired_events(repeated["radar_state"], now=now)
        self.assertIsNone(next_path)
        self.assertIsNone(next_doc)
        self.assertEqual(after, repeated["radar_state"])

    def test_verified_news_never_leave_working_ledger(self):
        _, _, expired = expired_fixture()
        verified = run(fixture()["rows"], previous=expired, at=BASE+timedelta(days=2))["radar_state"]
        now = BASE+timedelta(days=4)
        before = project_master_news(verified, now=now)
        compact, _, _ = archive_expired_events(verified, now=now)
        self.assertEqual(project_master_news(compact, now=now), before)
        self.assertTrue(all(e.get("status") != "eligible" for e in compact["archive_index"].values()))

    def test_batch_is_bounded_and_previous_archive_is_append_only(self):
        _, event_id, old = expired_fixture()
        one = old["items"][event_id]
        old["items"] = {f"ttn2-{i:024x}": {**copy.deepcopy(one), "event_id": f"ttn2-{i:024x}"}
                        for i in range(MAX_BATCH_ITEMS + 12)}
        now = BASE+timedelta(days=4)
        first, path_a, doc_a = archive_expired_events(old, now=now)
        self.assertEqual(doc_a["count"], MAX_BATCH_ITEMS)
        second, path_b, doc_b = archive_expired_events(first, now=now)
        self.assertEqual(doc_b["count"], 12)
        self.assertNotEqual(path_a, path_b)
        self.assertEqual(len(second["archive_index"]), MAX_BATCH_ITEMS+12)
        self.assertEqual(len(second["items"]), 0)
        self.assertEqual(second["archive_manifest"][0]["sha256"], sha256(doc_a))
        self.assertEqual(second["archive_manifest"][1]["sha256"], sha256(doc_b))

    def test_live_atomic_commit_contains_full_archive_and_preserves_master(self):
        _, event_id, old = expired_fixture()
        now = BASE + timedelta(days=4)
        fetched = fixture()
        class InventoryStore(BranchStore):
            def inventory(self, commit):
                return self.commits[commit]
        radar = InventoryStore(RADAR_LIVE_BRANCH, {RADAR_PATH: old})
        editorial = BranchStore(BRANCH, {INDEX_PATH: {"project": "ttittulares-v2", "items": {}}})
        result = persist_live(fetched, radar, editorial, now=now)
        self.assertTrue(result["verified"])
        self.assertEqual(result["archived_in_batch"], 1)
        written = radar.commits[radar.current]
        archive_path = next(p for p in written if p.startswith(ARCHIVE_PREFIX))
        self.assertIn(event_id, restore_archive(written[archive_path]))
        self.assertNotIn(event_id, written[RADAR_PATH]["items"])
        self.assertEqual(written[MASTER_PATH]["count"], project_master_news(written[RADAR_PATH], now=now)["count"])
        self.assertEqual(editorial.write_count, 0)
        # The archive path must never be overwritten, even by a replay.
        later = persist_live(fetched, radar, editorial, now=now+timedelta(minutes=15))
        self.assertEqual(later["archived_in_batch"], 0)
        self.assertEqual(radar.commits[radar.current][archive_path], written[archive_path])

    def test_existing_archive_path_is_not_overwritten_on_a_new_scan(self):
        _, _, old = expired_fixture()
        now = BASE + timedelta(days=4)
        fetched = fixture()
        planned = ingest_scan(fetched["rows"], fetched["source_statuses"], copy.deepcopy(old),
                              {"project":"ttittulares-v2","items":{}}, now=now)
        _, reserved_path, _ = archive_expired_events(planned["radar_state"],now=now)
        class InventoryStore(BranchStore):
            def inventory(self, commit):
                return self.commits[commit]
        sentinel={"historical": "must remain unchanged"}
        radar=InventoryStore(RADAR_LIVE_BRANCH,{RADAR_PATH:old,reserved_path:sentinel})
        editorial=BranchStore(BRANCH,{INDEX_PATH:{"project":"ttittulares-v2","items":{}}})
        with self.assertRaisesRegex(StoreError,"RADAR_ARCHIVE_FILE_EXISTS"):
            persist_live(fetched,radar,editorial,now=now)
        self.assertEqual(radar.write_count,0)
        self.assertEqual(radar.commits[radar.current][reserved_path],sentinel)


if __name__ == "__main__":
    unittest.main()
