"""V1 selection parity: duplicate suppression, 4-family quorum unchanged, no data deletion."""
import copy
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from .selection_v1_parity_v2 import existing_story, same_editorial_fact
from .radar_snapshot_v2 import plan_snapshot, PREFIX
from .test_radar_snapshot_v2 import fixture

NOW = datetime(2026, 11, 18, 20, 0, tzinfo=timezone.utc)
FIRST = "2026-11-18T19:20:00Z"
OLD = "ttn2-" + "1" * 24
NEW = "ttn2-" + "2" * 24
TITLE = "Muere el fundador de Núcleo Nacional, Enrique Lemus, tras sufrir un infarto"


def indexed(title=TITLE, status="ready", stamp=FIRST, editorial=True):
    return {"event_id": OLD, "canonical_title": title, "aliases": [],
            "first_seen_at": stamp, "status": status,
            "editorial_created": editorial, "revision_refs": ([{"revision": 1}] if editorial else [])}


def candidate(title=TITLE, revision=1):
    return {"event_id": NEW, "revision": revision,
            "canonical_title": title, "first_seen_at": FIRST}


class V1SelectionParity(unittest.TestCase):
    def test_same_title_has_single_editorial_identity(self):
        self.assertEqual(existing_story(candidate(), {OLD: indexed()}, now=NOW), OLD)

    def test_terminal_decisions_are_not_reopened_under_a_new_id(self):
        for status in ("published", "dismissed", "archived", "deleted"):
            with self.subTest(status=status):
                self.assertEqual(existing_story(candidate(), {OLD: indexed(status=status)}, now=NOW), OLD)

    def test_weak_candidate_cannot_block_new_verified_story(self):
        self.assertIsNone(existing_story(candidate(), {OLD: indexed(editorial=False)}, now=NOW))

    def test_material_update_keeps_authorized_revision_path(self):
        self.assertIsNone(existing_story(candidate(revision=2), {OLD: indexed()}, now=NOW))

    def test_distinct_events_and_numbers_are_not_merged(self):
        distinct = "Fallece un hombre tras un incendio en Bilbao"
        self.assertFalse(same_editorial_fact(TITLE, distinct))
        self.assertFalse(same_editorial_fact("Un accidente deja 2 heridos en Valencia",
                                             "Un accidente deja 4 heridos en Valencia"))

    def test_different_day_recurrent_headline_does_not_block_forever(self):
        old = indexed(stamp="2026-11-15T11:00:00Z")
        self.assertIsNone(existing_story(candidate(), {OLD: old}, now=NOW))

    def test_generic_live_headline_never_folds_distinct_events(self):
        self.assertFalse(same_editorial_fact("Última hora de la campaña electoral",
                                             "Última hora de la campaña electoral"))

    def test_v1_variant_of_pattinson_case_is_grouped(self):
        self.assertTrue(same_editorial_fact(
            "El actor británico Robert Pattinson será el próximo James Bond",
            "El actor británico Robert Pattinson será el nuevo James Bond"))

    def test_plan_materialization_does_not_create_duplicate_authority(self):
        # Create the first verified story as the original immutable authority.
        first = plan_snapshot(fixture(), {}, now=NOW)
        docs = copy.deepcopy(first["writes"])
        path = next(p for p in docs if p.startswith(PREFIX + "news/"))
        existing_id = docs[path]["event_id"]
        title = docs[path]["identity"]["canonical_title"]
        # The second scan incorrectly presents an alternative eligible ID;
        # the second editorial selection barrier must refuse it.
        from .radar_ingest_v2 import ingest_scan
        result = ingest_scan(fixture()["rows"], fixture()["source_statuses"],
                             None, None, now=NOW + timedelta(minutes=10))
        prior_id = result["newly_eligible"][0]["event_id"]
        duplicate_id = NEW if prior_id != NEW else OLD
        result["newly_eligible"][0]["event_id"] = duplicate_id
        item = result["news_index"]["items"].pop(prior_id)
        item["event_id"] = duplicate_id
        item["canonical_title"] = title
        result["news_index"]["items"][duplicate_id] = item
        # Mocked ingest must preserve the prior authoritative news item,
        # exactly as a real scan against a populated index does.
        result["news_index"]["items"].update(
            copy.deepcopy(docs[PREFIX + "state/news-index.json"]["items"]))
        radar_item = result["radar_state"]["items"].pop(prior_id)
        radar_item["event_id"] = duplicate_id
        result["radar_state"]["items"][duplicate_id] = radar_item
        with patch("v2.ttittulares.radar_snapshot_v2.ingest_scan", return_value=result):
            plan = plan_snapshot(fixture(), docs, now=NOW + timedelta(minutes=10))
        self.assertEqual(plan["new_job_count"], 0)
        self.assertEqual(plan["queue"]["pending_count"], 1)
        self.assertFalse(any(k.startswith(PREFIX + "jobs/editorial/"+duplicate_id)
                             for k in plan["writes"]))
        duplicate = plan["writes"][PREFIX + "state/news-index.json"]["items"][duplicate_id]
        self.assertEqual(duplicate["status"], "archived")
        self.assertFalse(duplicate["editorial_created"])


if __name__ == "__main__":
    unittest.main()
