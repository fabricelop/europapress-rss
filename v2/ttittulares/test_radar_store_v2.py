"""Synthetic atomic store and wire-contract regressions. No network or real commits."""
import base64
import copy
import hashlib
import json
import unittest
from datetime import timedelta
from pathlib import Path

from .radar_store_v2 import (GitHubStore, StoreError, Conflict, UncertainCommit,
                             REPOSITORY, BRANCH, PREFIX, persist_snapshot, validate_plan,
                             LIVE_RETRY_BUDGET, SNAPSHOT_READ_WORKERS, PINNED_JSON_MAX_BYTES)
from .radar_snapshot_v2 import encode, plan_snapshot, sha256
from .test_radar_snapshot_v2 import fixture
from .test_radar_ingest_v2 import BASE


class MemoryStore:
    def __init__(self, documents=None):
        self.current = "a" * 40
        self.commits = {self.current: copy.deepcopy(documents or {})}
        self.write_count = 0
        self.read_commits = []
        self.before_commit = None
        self.lose_response = False
        self.break_readback = False
        self.always_conflict = False
        self.fail_reads = False

    def advance(self, changes):
        self.current = hashlib.sha1(str(len(self.commits)).encode()).hexdigest()
        self.commits[self.current] = {**copy.deepcopy(list(self.commits.values())[-1]), **copy.deepcopy(changes)}

    def read_snapshot(self, receipt_path):
        if self.fail_reads:
            raise StoreError("READ_FAILURE_FIXTURE")
        return self.current, copy.deepcopy(self.commits[self.current])

    def origin_commit(self, head, path):
        return next(commit for commit, docs in self.commits.items() if path in docs)

    def read_documents(self, commit, paths):
        self.read_commits.append(commit)
        docs = {p: copy.deepcopy(self.commits[commit][p]) for p in paths}
        if self.break_readback:
            docs.pop(next(iter(docs)))
        return docs

    def commit(self, expected, writes, message):
        if self.before_commit:
            hook, self.before_commit = self.before_commit, None
            hook(self)
        if self.always_conflict or expected != self.current:
            raise Conflict("CONFLICT_FIXTURE")
        self.advance(writes)
        self.write_count += 1
        if self.lose_response:
            self.lose_response = False
            raise UncertainCommit("RESPONSE_LOST_FIXTURE")
        return self.current


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.fetch = fixture()
        self.store = MemoryStore()

    def test_one_atomic_commit_contains_event_job_state_and_receipt(self):
        result = persist_snapshot(self.store, self.fetch, now=BASE)
        self.assertTrue(result["verified"])
        self.assertEqual(self.store.write_count, 1)
        self.assertEqual(result["files_verified"], 8)
        self.assertEqual(result["new_job_count"], 1)
        self.assertFalse(result["editorial_execution_enabled"])
        self.assertFalse(result["publication_enabled"])
        self.assertTrue(all(p.startswith(PREFIX) for p in self.store.commits[self.store.current]))

    def test_materialization_commit_omits_large_radar_and_scan_blobs(self):
        existing_radar = plan_snapshot(self.fetch, {}, now=BASE)["writes"][PREFIX + "state/radar/current.json"]
        existing_radar["items"] = {}
        self.store = MemoryStore({PREFIX + "state/radar/current.json":existing_radar})
        result = persist_snapshot(self.store, self.fetch, now=BASE + timedelta(minutes=5), materialize_only=True)
        self.assertTrue(result["verified"])
        self.assertEqual(result["new_job_count"], 1)
        docs = self.store.commits[self.store.current]
        self.assertEqual(docs[PREFIX + "state/radar/current.json"], existing_radar)
        receipt = docs[result["receipt_path"]]
        self.assertFalse(any(p.startswith(PREFIX + "state/radar/") for p in receipt["file_sha256"]))
        self.assertIn(PREFIX + "state/editorial-queue.json", receipt["file_sha256"])
        self.assertTrue(any(p.startswith(PREFIX + "jobs/editorial/") for p in receipt["file_sha256"]))

    def test_same_input_replay_verifies_original_commit_without_second_write(self):
        first = persist_snapshot(self.store, self.fetch, now=BASE)
        self.store.advance({"v2/ttendencias/state/fixture.json": {"unrelated": True}})
        second = persist_snapshot(self.store, self.fetch, now=BASE)
        self.assertTrue(second["replayed"])
        self.assertEqual(first["commit_sha"], second["commit_sha"])
        self.assertEqual(self.store.write_count, 1)
        self.assertEqual(self.store.read_commits[-1], first["commit_sha"])

    def test_lost_commit_response_reconciles_receipt_before_retry(self):
        self.store.lose_response = True
        result = persist_snapshot(self.store, self.fetch, now=BASE)
        self.assertTrue(result["replayed"])
        self.assertEqual(self.store.write_count, 1)

    def test_lost_response_on_last_attempt_is_reconciled(self):
        self.store.lose_response = True
        result = persist_snapshot(self.store, self.fetch, now=BASE, max_attempts=1)
        self.assertTrue(result["verified"])
        self.assertEqual(self.store.write_count, 1)

    def test_concurrent_unrelated_commit_is_preserved_and_plan_recomputed(self):
        self.store.before_commit = lambda store: store.advance({"v2/ttendencias/state/fixture.json": {"keep": True}})
        result = persist_snapshot(self.store, self.fetch, now=BASE)
        self.assertEqual(result["attempts"], 2)
        self.assertEqual(self.store.commits[self.store.current]["v2/ttendencias/state/fixture.json"], {"keep": True})
        self.assertEqual(self.store.write_count, 1)

    def test_live_budget_recovers_after_five_unrelated_writes_without_losing_any(self):
        store = self.store
        original_commit = store.commit
        collision_count = 0
        def with_bursts(expected, writes, message):
            nonlocal collision_count
            if collision_count < 5:
                collision_count += 1
                store.advance({"v2/ttendencias/state/fixture.json": {"burst": collision_count}})
            return original_commit(expected, writes, message)
        store.commit = with_bursts
        self.assertEqual(LIVE_RETRY_BUDGET, 8)
        self.assertEqual(SNAPSHOT_READ_WORKERS, 24)
        result = persist_snapshot(store, self.fetch, now=BASE, max_attempts=LIVE_RETRY_BUDGET)
        self.assertEqual(result["attempts"], 6)
        self.assertEqual(store.write_count, 1)
        self.assertEqual(store.commits[store.current]["v2/ttendencias/state/fixture.json"], {"burst": 5})

    def test_pure_radar_ci_ignores_runtime_state_writes(self):
        path = Path(__file__).resolve().parents[2] / ".github/workflows/ttittulares-v2-radar-ci.yml"
        if not path.exists():
            # Editorial CI uses sparse-checkout and intentionally excludes
            # unrelated workflows. Verify this invariant on full checkouts.
            self.skipTest("radar workflow not present in sparse CI checkout")
        workflow = path.read_text(encoding="utf-8")
        self.assertNotIn("'v2/ttittulares/**'", workflow)
        self.assertIn("'v2/ttittulares/*.py'", workflow)
        self.assertIn("'v2/ttittulares/schemas/**'", workflow)

    def test_human_dismissal_winning_race_is_not_overwritten(self):
        persist_snapshot(self.store, self.fetch, now=BASE)
        news_path = next(p for p in self.store.commits[self.store.current] if p.startswith(PREFIX + "news/"))
        def dismiss(store):
            event = copy.deepcopy(store.commits[store.current][news_path])
            event["status"] = "dismissed"
            store.advance({news_path: event})
        self.store.before_commit = dismiss
        result = persist_snapshot(self.store, self.fetch, now=BASE + timedelta(minutes=5))
        self.assertEqual(result["attempts"], 2)
        docs = self.store.commits[self.store.current]
        self.assertEqual(docs[news_path]["status"], "dismissed")
        self.assertEqual(docs[PREFIX + "state/editorial-queue.json"]["items"], [])

    def test_worker_claim_winning_race_keeps_exact_job(self):
        persist_snapshot(self.store, self.fetch, now=BASE)
        job_path = next(p for p in self.store.commits[self.store.current] if p.startswith(PREFIX + "jobs/"))
        claimed = copy.deepcopy(self.store.commits[self.store.current][job_path])
        claimed["status"] = "claimed"
        claimed["attempts"]["claim_count"] = 1
        self.store.before_commit = lambda store: store.advance({job_path: claimed})
        persist_snapshot(self.store, self.fetch, now=BASE + timedelta(minutes=5))
        self.assertEqual(self.store.commits[self.store.current][job_path], claimed)

    def test_newer_scan_winning_race_blocks_old_input(self):
        newer = plan_snapshot(self.fetch, {}, now=BASE + timedelta(minutes=5))["writes"]
        self.store.before_commit = lambda store: store.advance(newer)
        with self.assertRaisesRegex(StoreError, "NEWER_RADAR"):
            persist_snapshot(self.store, self.fetch, now=BASE)
        self.assertEqual(self.store.write_count, 0)

    def test_read_failure_is_never_treated_as_empty_store(self):
        self.store.fail_reads = True
        with self.assertRaisesRegex(StoreError, "READ_FAILURE"):
            persist_snapshot(self.store, self.fetch, now=BASE)
        self.assertEqual(self.store.write_count, 0)

    def test_missing_readback_does_not_report_success_and_retry_can_reconcile(self):
        self.store.break_readback = True
        with self.assertRaisesRegex(ValueError, "READBACK_MISMATCH"):
            persist_snapshot(self.store, self.fetch, now=BASE)
        self.store.break_readback = False
        self.assertTrue(persist_snapshot(self.store, self.fetch, now=BASE)["verified"])
        self.assertEqual(self.store.write_count, 1)

    def test_conflict_budget_exhaustion_writes_nothing(self):
        self.store.always_conflict = True
        with self.assertRaisesRegex(StoreError, "RETRY_BUDGET"):
            persist_snapshot(self.store, self.fetch, now=BASE, max_attempts=2)
        self.assertEqual(self.store.write_count, 0)

    def test_all_sources_failed_writes_nothing(self):
        for row in self.fetch["source_statuses"]:
            row["ok"] = False
        with self.assertRaisesRegex(StoreError, "NO_SOURCE_SUCCEEDED"):
            persist_snapshot(self.store, self.fetch, now=BASE)

    def test_scope_and_hash_tampering_rejected_before_write(self):
        for path, mutate in [("ttittulares/prepared.json", False), (PREFIX + "state/news-index.json", True)]:
            plan = plan_snapshot(self.fetch, {}, now=BASE)
            if mutate:
                plan["writes"][path]["tampered"] = True
            else:
                plan["writes"][path] = {}
                plan["file_sha256"][path] = sha256({})
            with self.assertRaisesRegex(StoreError, "PLAN_PATH_OR_HASH"):
                validate_plan(plan, {})

    def test_existing_jobs_cannot_be_overwritten_by_plan(self):
        plan = plan_snapshot(self.fetch, {}, now=BASE)
        job_path = next(p for p in plan["writes"] if p.startswith(PREFIX + "jobs/"))
        with self.assertRaisesRegex(StoreError, "CANNOT_OVERWRITE_JOB"):
            validate_plan(plan, {job_path: plan["writes"][job_path]})

    def test_malformed_new_document_schema_rejected(self):
        plan = plan_snapshot(self.fetch, {}, now=BASE)
        path = next(p for p in plan["writes"] if p.startswith(PREFIX + "news/"))
        plan["writes"][path]["current_revision"] = 0
        plan["file_sha256"][path] = sha256(plan["writes"][path])
        with self.assertRaisesRegex(StoreError, "SCHEMA_INVALID"):
            validate_plan(plan, {})

    def test_bad_receipt_identity_is_not_accepted(self):
        result = persist_snapshot(self.store, self.fetch, now=BASE)
        self.store.commits[self.store.current][result["receipt_path"]]["input_sha256"] = "f" * 64
        with self.assertRaisesRegex(StoreError, "RECEIPT_IDENTITY"):
            persist_snapshot(self.store, self.fetch, now=BASE)

    def test_naive_clock_rejected(self):
        with self.assertRaisesRegex(StoreError, "TIMEZONE_AWARE"):
            persist_snapshot(self.store, self.fetch, now=BASE.replace(tzinfo=None))

    def test_missing_authoritative_job_is_not_recreated(self):
        persist_snapshot(self.store, self.fetch, now=BASE)
        docs = self.store.commits[self.store.current]
        docs.pop(next(p for p in docs if p.startswith(PREFIX + "jobs/")))
        with self.assertRaisesRegex(StoreError, "MISSING_AUTHORITATIVE_JOB"):
            persist_snapshot(self.store, self.fetch, now=BASE + timedelta(minutes=5))

    def test_foreign_current_state_is_rejected(self):
        self.store.commits[self.store.current][PREFIX + "state/radar/current.json"] = {"project": "V1"}
        with self.assertRaisesRegex(StoreError, "SNAPSHOT_PROJECT"):
            persist_snapshot(self.store, self.fetch, now=BASE)

    def test_index_without_event_is_not_accepted(self):
        persist_snapshot(self.store, self.fetch, now=BASE)
        docs = self.store.commits[self.store.current]
        docs.pop(next(p for p in docs if p.startswith(PREFIX + "news/")))
        with self.assertRaisesRegex(StoreError, "INDEX_WITHOUT_AUTHORITATIVE_EVENT"):
            persist_snapshot(self.store, self.fetch, now=BASE + timedelta(minutes=5))


class WireTests(unittest.TestCase):
    def test_graphql_atomic_mutation_uses_expected_head_and_fixed_branch(self):
        calls = []
        def request(method, path, payload=None):
            calls.append((method, path, payload))
            return {"data": {"createCommitOnBranch": {"commit": {"oid": "b" * 40}}}}
        store = GitHubStore("fixture-not-a-real-token", request=request)
        path = PREFIX + "state/news-index.json"
        self.assertEqual(store.commit("a" * 40, {path: {"fixture": "á"}}, "test"), "b" * 40)
        method, endpoint, payload = calls[0]
        self.assertEqual((method, endpoint), ("POST", "/graphql"))
        data = payload["variables"]["input"]
        self.assertEqual(data["expectedHeadOid"], "a" * 40)
        self.assertEqual(data["branch"], {"repositoryNameWithOwner": REPOSITORY, "branchName": BRANCH})
        addition = data["fileChanges"]["additions"][0]
        self.assertEqual(json.loads(base64.b64decode(addition["contents"])), {"fixture": "á"})
        self.assertNotIn("deletions", data["fileChanges"])
        self.assertNotIn("force", payload["query"])

    def test_wire_refuses_v1_or_non_state_paths(self):
        store = GitHubStore("fixture", request=lambda *args: self.fail("unexpected API call"))
        for path in ("ttittulares/prepared.json", "v2/ttendencias/state/listas.json", PREFIX + "../escape.json"):
            with self.assertRaisesRegex(StoreError, "OUTSIDE_SCOPE"):
                store.commit("a" * 40, {path: {}}, "test")

    def test_graphql_error_with_moved_head_is_conflict(self):
        def request(method, path, payload=None):
            if method == "POST":
                return {"errors": [{"message": "opaque fixture"}]}
            return {"commit": {"sha": "b" * 40}}
        with self.assertRaises(Conflict):
            GitHubStore("fixture", request=request).commit("a" * 40, {PREFIX + "state/news-index.json": {}}, "test")

    def test_graphql_rejection_does_not_leak_api_body(self):
        def request(method, path, payload=None):
            return {"errors": [{"message": "PRIVATE_FIXTURE"}]} if method == "POST" else {"commit": {"sha": "a" * 40}}
        with self.assertRaisesRegex(StoreError, "^GITHUB_COMMIT_REJECTED$"):
            GitHubStore("fixture", request=request).commit("a" * 40, {PREFIX + "state/news-index.json": {}}, "test")

    def test_truncated_tree_fails_closed(self):
        store = GitHubStore("fixture", request=lambda *args: {"truncated": True, "tree": []})
        with self.assertRaisesRegex(StoreError, "INCOMPLETE_GIT_TREE"):
            store._tree("a" * 40)

    def test_blob_bytes_must_match_git_object_hash(self):
        raw = encode({"fixture": True}).encode()
        digest = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        store = GitHubStore("fixture", request=lambda *args: {"encoding": "base64", "content": base64.b64encode(raw).decode()})
        self.assertEqual(store._blob_json({"type": "blob", "mode": "100644", "sha": digest}), {"fixture": True})
        with self.assertRaisesRegex(StoreError, "BLOB_HASH_MISMATCH"):
            store._blob_json({"type": "blob", "mode": "100644", "sha": "a" * 40})

    def test_unchanged_blob_is_not_downloaded_again_after_branch_advances(self):
        path = PREFIX + "state/news-index.json"
        old_raw = encode({"items": {"first": 1}}).encode()
        new_raw = encode({"items": {"second": 2}}).encode()
        oid = lambda raw: hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        old_sha, new_sha = oid(old_raw), oid(new_raw)
        reads = []
        def read(commit, file_path):
            reads.append((commit, file_path))
            return old_raw if commit == "a" * 40 else new_raw
        store = GitHubStore("fixture", request=lambda *args: self.fail("unexpected API call"), read_bytes=read)
        store._inventories["a" * 40] = {path: {"type": "blob", "mode": "100644", "sha": old_sha}}
        store._inventories["b" * 40] = {path: {"type": "blob", "mode": "100644", "sha": old_sha}}
        first = store.read_documents("a" * 40, [path])
        first[path]["items"]["first"] = 999
        self.assertEqual(store.read_documents("b" * 40, [path])[path]["items"], {"first": 1})
        self.assertEqual(len(reads), 1)
        store._inventories["c" * 40] = {path: {"type": "blob", "mode": "100644", "sha": new_sha}}
        # This fixture retrieves the new object only after its SHA changes.
        store._read_bytes = lambda commit, file_path: reads.append((commit, file_path)) or new_raw
        self.assertEqual(store.read_documents("c" * 40, [path])[path]["items"], {"second": 2})
        self.assertEqual(len(reads), 2)

    def test_state_symlinks_are_rejected(self):
        with self.assertRaisesRegex(StoreError, "NOT_REGULAR"):
            GitHubStore("fixture")._blob_json({"type": "blob", "mode": "120000", "sha": "a" * 40})

    def test_pinned_reads_do_not_consult_current_branch(self):
        store = GitHubStore("fixture", request=lambda *args: self.fail("unexpected API call"))
        path = PREFIX + "state/news-index.json"
        store._inventories["b" * 40] = {path: {"fixture": True}}
        store._blob_json = lambda entry, commit, path: entry
        self.assertEqual(store.read_documents("b" * 40, [path]), {path: {"fixture": True}})
        with self.assertRaisesRegex(StoreError, "PINNED_DOCUMENT_MISSING"):
            store.read_documents("b" * 40, [PREFIX + "news/missing.json"])

    def test_subtree_reader_enumerates_only_news_at_pinned_commit(self):
        calls = []
        def request(method, path, payload=None):
            calls.append(path)
            if "/git/commits/" in path:
                return {"tree": {"sha": "b" * 40}}
            if path.endswith("b" * 40):
                return {"truncated": False, "tree": [{"path": "v2", "type": "tree", "sha": "c" * 40}]}
            if path.endswith("c" * 40):
                return {"truncated": False, "tree": [{"path": "ttittulares", "type": "tree", "sha": "d" * 40}]}
            return {"truncated": False, "tree": [{"path": "state/news-index.json", "type": "blob", "mode": "100644", "sha": "e" * 40}]}
        inventory = GitHubStore("fixture", request=request).inventory("a" * 40)
        self.assertEqual(list(inventory), [PREFIX + "state/news-index.json"])
        self.assertTrue(calls[-1].endswith("d" * 40 + "?recursive=1"))
        self.assertFalse(any("/branches/" in path for path in calls))

    def test_pinned_raw_read_uses_no_blob_api_and_checks_original_git_hash(self):
        raw = encode({"fixture": True}).encode()
        digest = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        path = PREFIX + "state/news-index.json"
        reads = []
        def read_bytes(commit, name):
            reads.append((commit, name))
            return raw
        store = GitHubStore("fixture", request=lambda *args: self.fail("unnecessary blob API"), read_bytes=read_bytes)
        store._inventories["b" * 40] = {path: {"type": "blob", "mode": "100644", "sha": digest}}
        self.assertEqual(store.read_documents("b" * 40, [path]), {path: {"fixture": True}})
        self.assertEqual(reads, [("b" * 40, path)])
        # The cache intentionally trusts an already hash-verified immutable blob.
        # A first-time tampered download must still fail closed.
        store = GitHubStore("fixture", request=lambda *args: self.fail("unnecessary blob API"),
                            read_bytes=lambda *args: b'{"tampered":true}')
        store._inventories["b" * 40] = {path: {"type": "blob", "mode": "100644", "sha": digest}}
        with self.assertRaisesRegex(StoreError, "BLOB_HASH_MISMATCH"):
            store.read_documents("b" * 40, [path])

    def test_raw_request_omits_credentials_and_uses_pinned_public_url(self):
        from io import BytesIO
        calls = []
        class Opener:
            def open(self, req, timeout):
                calls.append(req)
                return BytesIO(b'{}')
        store = GitHubStore("private-fixture-never-export")
        store._opener = Opener()
        path = PREFIX + "state/news-index.json"
        self.assertEqual(store._http_raw("b" * 40, path), b'{}')
        self.assertEqual(calls[0].get_header("Authorization"), None)
        self.assertIn("/" + "b" * 40 + "/" + path, calls[0].full_url)
        with self.assertRaisesRegex(StoreError, "OUTSIDE_SCOPE"):
            store._http_raw("b" * 40, "ttittulares/prepared.json")

    def test_pinned_historical_radar_larger_than_old_limit_is_read_intact(self):
        from io import BytesIO
        # The real radar crossed the former 16 MB cap. Preserve every byte:
        # no truncation or deletion of archived candidates is permissible here.
        payload = b'{"history":"' + b'x' * 16_100_000 + b'"}'
        calls = []
        class Opener:
            def open(self, req, timeout):
                return BytesIO(payload)
        store = GitHubStore("fixture")
        store._opener = Opener()
        result = store._http_raw("a" * 40, PREFIX + "state/radar/current.json")
        self.assertEqual(result, payload)
        self.assertGreater(len(result), 16_000_000)
        self.assertEqual(PINNED_JSON_MAX_BYTES, 64_000_000)

    def test_pinned_historical_radar_still_rejects_an_oversized_response(self):
        class TooLargeBytes(bytes):
            def __len__(self):
                return PINNED_JSON_MAX_BYTES + 1
        class Response:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return None
            def read(self, n):
                self.limit_seen = n
                return TooLargeBytes(b'{}')
        response = Response()
        class Opener:
            def open(self, req, timeout):
                return response
        store = GitHubStore("fixture")
        store._opener = Opener()
        with self.assertRaisesRegex(StoreError, "PINNED_RAW_READ_TOO_LARGE"):
            store._http_raw("a" * 40, PREFIX + "state/radar/current.json")
        self.assertEqual(response.limit_seen, PINNED_JSON_MAX_BYTES + 1)

    def test_replay_reads_only_receipt_before_origin_verification(self):
        store = GitHubStore("fixture")
        receipt_path = PREFIX + "state/radar/receipts/txn-" + "a" * 24 + ".json"
        store.head = lambda: "b" * 40
        store.inventory = lambda commit: {receipt_path: {}, PREFIX + "news/ttn2-" + "a" * 24 + ".json": {}}
        paths_read = []
        def read_documents(commit, paths):
            paths_read.extend(paths)
            return {receipt_path: {"fixture": True}}
        store.read_documents = read_documents
        head, docs = store.read_snapshot(receipt_path)
        self.assertEqual(paths_read, [receipt_path])
        self.assertEqual(head, "b" * 40)


if __name__ == "__main__":
    unittest.main()

