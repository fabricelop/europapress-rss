"""Synthetic regressions for fetch/ingest/snapshot boundary; no HTTP or Git writes."""
import copy
import json
import unittest
from datetime import timedelta
from pathlib import Path

from .radar_snapshot_v2 import PREFIX, BRANCH, plan_snapshot, verify_readback
from .test_radar_ingest_v2 import BASE, GENERAL, BY_NAME, make_row, statuses


def fixture():
    families, names = set(), []
    for name in GENERAL:
        family = BY_NAME[name]["family"]
        if family not in families:
            families.add(family)
            names.append(name)
    return {"rows": [make_row(name) for name in names[:4]], "source_statuses": statuses()}


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.fetch = fixture()
        self.plan = plan_snapshot(self.fetch, {}, now=BASE)
        self.docs = copy.deepcopy(self.plan["writes"])
        self.news_path = next(p for p in self.docs if p.startswith(PREFIX + "news/"))
        self.job_path = next(p for p in self.docs if p.startswith(PREFIX + "jobs/"))
        self.event = self.docs[self.news_path]
        self.event_id = self.event["event_id"]

    def test_quorum_produces_one_pending_job_and_separate_event(self):
        self.assertEqual(self.plan["new_job_count"], 1)
        self.assertEqual(self.event["status"], "editorial_pending")
        self.assertEqual(self.docs[self.job_path]["status"], "pending")
        self.assertIsNone(self.docs[self.job_path]["prompt"])
        self.assertEqual(self.plan["queue"]["pending_count"], 1)

    def test_under_quorum_keeps_only_radar_candidate(self):
        fetch = copy.deepcopy(self.fetch)
        fetch["rows"] = fetch["rows"][:3]
        plan = plan_snapshot(fetch, {}, now=BASE)
        self.assertEqual(plan["new_job_count"], 0)
        self.assertFalse(any(p.startswith(PREFIX + "news/") for p in plan["writes"]))
        self.assertEqual(plan["metrics"]["monitoring_count"], 1)

    def test_repeated_feed_does_not_overwrite_or_duplicate_job(self):
        plan = plan_snapshot(self.fetch, self.docs, now=BASE + timedelta(minutes=5))
        self.assertEqual(plan["new_job_count"], 0)
        self.assertNotIn(self.job_path, plan["writes"])
        self.assertNotIn(self.news_path, plan["writes"])
        self.assertEqual(len(plan["queue"]["items"]), 1)

    def test_claimed_job_lease_and_attempts_are_preserved(self):
        job = self.docs[self.job_path]
        job["status"] = "claimed"
        job["lease"] = {"opaque": "lease-fixture"}
        job["attempts"]["claim_count"] = 1
        before = copy.deepcopy(self.docs)
        plan = plan_snapshot(self.fetch, self.docs, now=BASE + timedelta(minutes=5))
        self.assertNotIn(self.job_path, plan["writes"])
        self.assertEqual(plan["queue"]["active_count"], 1)
        self.assertEqual(self.docs, before)

    def test_terminal_decisions_override_stale_radar(self):
        for status in ("published", "dismissed", "deleted", "archived"):
            with self.subTest(status=status):
                docs = copy.deepcopy(self.docs)
                docs[self.news_path]["status"] = status
                plan = plan_snapshot(self.fetch, docs, now=BASE + timedelta(minutes=5))
                self.assertEqual(plan["new_job_count"], 0)
                self.assertEqual(plan["queue"]["items"], [])
                item = plan["writes"][PREFIX + "state/news-index.json"]["items"][self.event_id]
                self.assertEqual(item["status"], status)

    def test_ready_is_not_reopened_by_more_sources_or_same_headline(self):
        self.event["status"] = "ready"
        self.event["revision_refs"][0]["status"] = "ready"
        self.docs[self.job_path]["status"] = "ready"
        plan = plan_snapshot(self.fetch, self.docs, now=BASE + timedelta(minutes=5))
        self.assertEqual(plan["new_job_count"], 0)
        self.assertNotIn(self.news_path, plan["writes"])
        self.assertNotIn(self.job_path, plan["writes"])
        self.assertEqual(plan["queue"]["pending_count"], 0)

    def test_ready_record_and_images_remain_untouched(self):
        paths = [PREFIX + f"records/{self.event_id}/r1.json",
                 PREFIX + f"images/manifests/{self.event_id}-r1.json",
                 PREFIX + f"decisions/{self.event_id}/decision-fixture.json"]
        for path in paths:
            self.docs[path] = {"synthetic": True}
        plan = plan_snapshot(self.fetch, self.docs, now=BASE + timedelta(minutes=5))
        self.assertFalse(set(paths) & set(plan["writes"]))

    def test_material_revision_keeps_old_ready_and_creates_one_new_job(self):
        old = "El Supremo mantiene la suspensión del derecho a voto por la ley de nietos"
        updated = "El Supremo confirma la condena por la suspensión del derecho a voto de los nacionalizados por la ley de nietos"
        self.event["identity"]["canonical_title"] = old
        self.event["identity"]["canonical_fact"] = old
        self.event["status"] = "ready"
        self.event["revision_refs"][0]["status"] = "ready"
        self.docs[self.job_path]["status"] = "ready"
        item = self.docs[PREFIX + "state/news-index.json"]["items"][self.event_id]
        item["source_families"] = ["Old Family A", "Old Family B"]
        item["aliases"] = [old]
        item["canonical_urls"] = ["https://example.org/original"]
        record_path = PREFIX + f"records/{self.event_id}/r1.json"
        self.docs[record_path] = {"synthetic_ready": True}
        fetch = {"rows": [make_row(n, updated, f"new-{i}") for i, n in enumerate(
                    ["EFE", "Servimedia", "elDiario.es", "Público"])], "source_statuses": statuses()}
        plan = plan_snapshot(fetch, self.docs, now=BASE + timedelta(minutes=5))
        self.assertEqual(plan["new_job_count"], 1)
        self.assertEqual(plan["writes"][self.news_path]["current_revision"], 2)
        self.assertEqual(plan["writes"][self.news_path]["revision_refs"][0]["status"], "ready")
        self.assertNotIn(record_path, plan["writes"])
        self.assertNotIn(self.job_path, plan["writes"])
        self.assertEqual(plan["queue"]["items"][0]["revision"], 2)

    def test_path_identity_mismatch_fails_closed(self):
        self.event["event_id"] = "ttn2-" + "a" * 24
        with self.assertRaisesRegex(ValueError, "NEWS_PATH_IDENTITY"):
            plan_snapshot(self.fetch, self.docs, now=BASE)

    def test_orphan_job_fails_closed(self):
        self.docs.pop(self.news_path)
        with self.assertRaisesRegex(ValueError, "ORPHAN_EDITORIAL_JOB"):
            plan_snapshot(self.fetch, self.docs, now=BASE)

    def test_wrong_project_fails_closed(self):
        self.event["project"] = "ttittulares-v1"
        with self.assertRaisesRegex(ValueError, "AUTHORITY_PROJECT"):
            plan_snapshot(self.fetch, self.docs, now=BASE)

    def test_failed_or_partial_fetch_shape_is_not_an_empty_scan(self):
        with self.assertRaisesRegex(ValueError, "INVALID_FETCH_RESULT"):
            plan_snapshot({"source_statuses": []}, {}, now=BASE)

    def test_naive_clock_rejected(self):
        with self.assertRaisesRegex(ValueError, "TIMEZONE_AWARE"):
            plan_snapshot(self.fetch, {}, now=BASE.replace(tzinfo=None))

    def test_inputs_are_not_mutated(self):
        fetch, docs = copy.deepcopy(self.fetch), copy.deepcopy(self.docs)
        plan_snapshot(self.fetch, self.docs, now=BASE + timedelta(minutes=5))
        self.assertEqual(self.fetch, fetch)
        self.assertEqual(self.docs, docs)

    def test_same_snapshot_input_produces_identical_plan(self):
        self.assertEqual(self.plan, plan_snapshot(self.fetch, {}, now=BASE))

    def test_only_v2_paths_and_no_effects(self):
        self.assertTrue(all(p.startswith(PREFIX) for p in self.plan["writes"]))
        self.assertEqual(self.plan["branch"], BRANCH)
        self.assertFalse(self.plan["effects_enabled"])
        self.assertFalse(self.plan["publication_enabled"])
        self.assertFalse(any("records/" in p or "images/" in p for p in self.plan["writes"]))

    def test_readback_requires_every_file_and_exact_hash(self):
        self.assertTrue(verify_readback(self.plan, self.docs))
        for mode in ("missing", "altered"):
            docs = copy.deepcopy(self.docs)
            if mode == "missing":
                del docs[self.job_path]
            else:
                docs[self.job_path]["revision"] = 99
            with self.assertRaisesRegex(ValueError, "READBACK_MISMATCH"):
                verify_readback(self.plan, docs)

    def test_changed_title_or_health_at_same_time_has_different_scan_identity(self):
        fetch = copy.deepcopy(self.fetch)
        fetch["source_statuses"][0]["latency_ms"] = 999
        self.assertNotEqual(self.plan["scan_id"], plan_snapshot(fetch, {}, now=BASE)["scan_id"])

    def test_new_documents_validate_against_contract(self):
        from jsonschema import Draft202012Validator, FormatChecker
        schema = json.loads((Path(__file__).parent / "schemas/contract.schema.json").read_text(encoding="utf-8"))
        for doc, name in [(self.event, "news_event"), (self.docs[self.job_path], "editorial_job"),
                          (self.plan["queue"], "queue_index")]:
            validator = Draft202012Validator({"$ref": f"#/$defs/{name}", "$defs": schema["$defs"]},
                                             format_checker=FormatChecker())
            validator.validate(doc)
        invalid = copy.deepcopy(self.docs[self.job_path])
        invalid["status"] = "send_intent"
        validator = Draft202012Validator({"$ref": "#/$defs/editorial_job", "$defs": schema["$defs"]})
        self.assertFalse(validator.is_valid(invalid))

    def test_cached_identity_preserves_uncached_scores_and_has_bounded_memory(self):
        from .identity_v2 import (title_match_value, title_score, same_event_semantic,
                                 _title_match_value, _token_values, _proper_token_values)
        titles = [row["title"] for row in self.fetch["rows"]] + [
            "El Supremo mantiene la suspensión del derecho a voto por la ley de nietos",
            "El Supremo confirma la condena por la ley de nietos",
            "Un incendio obliga a desalojar un colegio de Ceuta",
            "Los bomberos rescatan a dos personas en Málaga",
            "El Gobierno aprueba la medida después del debate parlamentario"]
        for left in titles:
            for right in titles:
                score = title_score(left, right)
                expected = max(score, 0.72) if same_event_semantic(left, right) else score
                self.assertEqual(title_match_value(left, right), expected)
        self.assertEqual(_title_match_value.cache_info().maxsize, 16384)
        self.assertEqual(_token_values.cache_info().maxsize, 8192)
        self.assertEqual(_proper_token_values.cache_info().maxsize, 8192)

    def test_mutating_returned_tokens_cannot_poison_cached_identity(self):
        from .identity_v2 import tokens, proper_tokens, fingerprint
        title = "El Gobierno de Pedro Sánchez aprueba la medida"
        before = fingerprint(title)
        tokens(title).clear()
        proper_tokens(title).clear()
        self.assertEqual(fingerprint(title), before)
        self.assertIn("pedro", proper_tokens(title))


if __name__ == "__main__":
    unittest.main()

