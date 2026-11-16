#!/usr/bin/env python3
"""Pinned V2 reads and one atomic, idempotent GitHub snapshot transaction.

No scheduler, browser, editorial execution or publication. Only --persist writes.
GitHub createCommitOnBranch uses expectedHeadOid as a server-side CAS.
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import copy
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, HTTPRedirectHandler, build_opener

from .radar_snapshot_v2 import PREFIX, BRANCH, encode, sha256, plan_snapshot, verify_readback
from .source_fetch_v2 import fetch_all_sources
from .source_publication_v2 import utc_iso

REPOSITORY = "fabricelop/europapress-rss"
OID = re.compile(r"[a-f0-9]{40}\Z")
HASH = re.compile(r"[a-f0-9]{64}\Z")
FIXED_STATE = {PREFIX + path for path in (
    "state/radar/current.json", "state/radar/source-health.json",
    "state/news-index.json", "state/editorial-queue.json")}
WRITE_PATH = re.compile(r"v2/ttittulares/(?:news/ttn2-[a-f0-9]{24}|"
                        r"jobs/editorial/ttn2-[a-f0-9]{24}-r[1-9][0-9]*-editorial|"
                        r"state/radar/scans/scan-[a-f0-9]{24})\.json\Z")
RECEIPT_PATH = re.compile(r"v2/ttittulares/state/radar/receipts/txn-[a-f0-9]{24}\.json\Z")


class StoreError(RuntimeError):
    """Only coded errors, never API bodies, credentials or raw transport exceptions."""


class Conflict(StoreError):
    pass


class UncertainCommit(StoreError):
    pass


def _oid(value):
    if not isinstance(value, str) or not OID.fullmatch(value):
        raise StoreError("INVALID_COMMIT_OR_TREE_OID")
    return value


def allowed_write(path):
    return path in FIXED_STATE or bool(WRITE_PATH.fullmatch(path))


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise StoreError("GITHUB_REDIRECT_REFUSED")


class GitHubStore:
    """The repository and branch are intentionally not configurable."""

    def __init__(self, token, *, request=None):
        if not token:
            raise StoreError("GITHUB_TOKEN_REQUIRED")
        self._token = token
        self._opener = build_opener(NoRedirect())
        self._request = request or self._http_json
        self._inventories = {}

    def _http_json(self, method, path, payload=None):
        if not (path.startswith("/repos/" + REPOSITORY + "/") or path == "/graphql"):
            raise StoreError("GITHUB_ENDPOINT_OUTSIDE_SCOPE")
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = Request("https://api.github.com" + path, data=body, method=method, headers={
            "Authorization": "Bearer " + self._token, "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "TTiTTulares-V2-Radar",
            "Content-Type": "application/json"})
        try:
            with self._opener.open(req, timeout=60) as response:
                raw = response.read(32_000_001)
            if len(raw) > 32_000_000:
                raise StoreError("GITHUB_RESPONSE_TOO_LARGE")
            return json.loads(raw)
        except HTTPError as exc:
            if method == "POST" and exc.code >= 500:
                raise UncertainCommit("GITHUB_COMMIT_RESPONSE_UNCERTAIN") from None
            raise StoreError("GITHUB_HTTP_" + str(exc.code)) from None
        except (URLError, TimeoutError, ConnectionError, OSError):
            if method == "POST":
                raise UncertainCommit("GITHUB_COMMIT_RESPONSE_UNCERTAIN") from None
            raise StoreError("GITHUB_READ_FAILED") from None
        except (ValueError, UnicodeError):
            if method == "POST":
                raise UncertainCommit("GITHUB_COMMIT_RESPONSE_UNCERTAIN") from None
            raise StoreError("GITHUB_JSON_INVALID") from None

    def _get(self, suffix):
        return self._request("GET", "/repos/" + REPOSITORY + suffix)

    def head(self):
        return _oid(self._get("/branches/" + quote(BRANCH, safe=""))["commit"]["sha"])

    def _tree(self, oid, recursive=False):
        result = self._get("/git/trees/" + _oid(oid) + ("?recursive=1" if recursive else ""))
        if result.get("truncated") is not False or not isinstance(result.get("tree"), list):
            raise StoreError("INCOMPLETE_GIT_TREE")
        return result["tree"]

    def inventory(self, commit):
        commit = _oid(commit)
        if commit in self._inventories:
            return self._inventories[commit]
        root = self._get("/git/commits/" + commit)
        tree = self._tree(root["tree"]["sha"])
        # Traverse only V2 news. Never enumerate or download V1 states or binary assets.
        for segment in ("v2", "ttittulares"):
            entry = next((x for x in tree if x["path"] == segment), None)
            if entry is None:
                inventory = {}
                break
            if entry.get("type") != "tree":
                raise StoreError("INVALID_NEWS_SUBTREE")
            tree = self._tree(entry["sha"], recursive=segment == "ttittulares")
        else:
            inventory = {PREFIX + x["path"]: x for x in tree}
        if len(self._inventories) >= 8:
            self._inventories.clear()
        self._inventories[commit] = inventory
        return inventory

    def _blob_json(self, entry):
        if entry.get("type") != "blob" or entry.get("mode") != "100644":
            raise StoreError("STATE_IS_NOT_REGULAR_JSON_FILE")
        blob = self._get("/git/blobs/" + _oid(entry["sha"]))
        if blob.get("encoding") != "base64":
            raise StoreError("GITHUB_BLOB_ENCODING_INVALID")
        try:
            raw = base64.b64decode("".join(blob["content"].split()), validate=True)
            actual = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
            if actual != entry["sha"]:
                raise StoreError("GITHUB_BLOB_HASH_MISMATCH")
            doc = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeError, KeyError):
            raise StoreError("GITHUB_BLOB_JSON_INVALID") from None
        if not isinstance(doc, dict):
            raise StoreError("STATE_DOCUMENT_MUST_BE_OBJECT")
        return doc

    def read_documents(self, commit, paths):
        inventory = self.inventory(commit)
        paths = list(paths)
        if any(path not in inventory for path in paths):
            raise StoreError("PINNED_DOCUMENT_MISSING")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            docs = list(pool.map(lambda path: self._blob_json(inventory[path]), paths))
        return dict(zip(paths, docs))

    def read_snapshot(self, receipt_path):
        head = self.head()
        inventory = self.inventory(head)
        paths = [path for path, entry in inventory.items() if
                 path in FIXED_STATE or path == receipt_path or
                 (entry["type"] != "tree" and path.startswith(
                     (PREFIX + "news/", PREFIX + "jobs/editorial/")))]
        docs = self.read_documents(head, paths)
        news = [p for p in docs if p.startswith(PREFIX + "news/")]
        if news and not {PREFIX + "state/news-index.json", PREFIX + "state/radar/current.json"} <= docs.keys():
            raise StoreError("AUTHORITIES_WITHOUT_RADAR_INDEX")
        return head, docs

    def origin_commit(self, head, path):
        rows = self._get("/commits?" + urlencode({"sha": _oid(head), "path": path, "per_page": 1}))
        if not isinstance(rows, list) or len(rows) != 1:
            raise StoreError("RECEIPT_ORIGIN_NOT_FOUND")
        return _oid(rows[0]["sha"])

    def commit(self, expected_head, writes, message):
        _oid(expected_head)
        if not writes or any(not (allowed_write(p) or RECEIPT_PATH.fullmatch(p)) for p in writes):
            raise StoreError("COMMIT_PATH_OUTSIDE_SCOPE")
        additions = [{"path": path, "contents": base64.b64encode(encode(doc).encode()).decode("ascii")}
                     for path, doc in sorted(writes.items())]
        result = self._request("POST", "/graphql", {
            "query": "mutation($input:CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid}}}",
            "variables": {"input": {
                "branch": {"repositoryNameWithOwner": REPOSITORY, "branchName": BRANCH},
                "expectedHeadOid": expected_head, "message": {"headline": message},
                "fileChanges": {"additions": additions}}}})
        if result.get("errors"):
            # Do not classify conflicts by human-language API messages or expose them.
            if self.head() != expected_head:
                raise Conflict("GITHUB_HEAD_CHANGED")
            raise StoreError("GITHUB_COMMIT_REJECTED")
        try:
            return _oid(result["data"]["createCommitOnBranch"]["commit"]["oid"])
        except (KeyError, TypeError):
            raise UncertainCommit("GITHUB_COMMIT_RESPONSE_UNCERTAIN") from None


def validate_plan(plan, documents):
    if plan.get("branch") != BRANCH or plan.get("effects_enabled") is not False or plan.get("publication_enabled") is not False:
        raise StoreError("PLAN_EFFECTS_OR_BRANCH_INVALID")
    if set(plan["writes"]) != set(plan["file_sha256"]):
        raise StoreError("PLAN_HASH_SET_MISMATCH")
    from jsonschema import Draft202012Validator, FormatChecker
    schema = json.loads((Path(__file__).parent / "schemas/contract.schema.json").read_text())
    for path, doc in plan["writes"].items():
        if not allowed_write(path) or sha256(doc) != plan["file_sha256"][path]:
            raise StoreError("PLAN_PATH_OR_HASH_INVALID")
        if path.startswith(PREFIX + "jobs/") and path in documents:
            raise StoreError("RADAR_CANNOT_OVERWRITE_JOB")
        if "/scans/" in path and path in documents and doc != documents[path]:
            raise StoreError("RADAR_CANNOT_OVERWRITE_SCAN")
        kind = ("news_event" if path.startswith(PREFIX + "news/") else
                "editorial_job" if path.startswith(PREFIX + "jobs/") else
                "queue_index" if path == PREFIX + "state/editorial-queue.json" else None)
        if kind:
            validator = Draft202012Validator({"$ref": "#/$defs/" + kind, "$defs": schema["$defs"]},
                                             format_checker=FormatChecker())
            if not validator.is_valid(doc):
                raise StoreError("PLAN_DOCUMENT_SCHEMA_INVALID")


def validate_snapshot(documents):
    for path in (PREFIX + "state/radar/current.json", PREFIX + "state/news-index.json",
                 PREFIX + "state/editorial-queue.json"):
        if path in documents and documents[path].get("project") != "ttittulares-v2":
            raise StoreError("SNAPSHOT_PROJECT_MISMATCH")
    for path, event in documents.items():
        if not path.startswith(PREFIX + "news/"):
            continue
        for ref in event.get("revision_refs", []):
            job_path = PREFIX + "jobs/editorial/" + ref["editorial_job_id"] + ".json"
            if job_path not in documents:
                raise StoreError("MISSING_AUTHORITATIVE_JOB")
    index = documents.get(PREFIX + "state/news-index.json", {}).get("items", {})
    for event_id, item in index.items():
        if item.get("editorial_created") and PREFIX + "news/" + event_id + ".json" not in documents:
            raise StoreError("INDEX_WITHOUT_AUTHORITATIVE_EVENT")


def _verify_receipt(store, commit, path, receipt, input_sha):
    if (receipt.get("project") != "ttittulares-v2" or receipt.get("schema_version") != 1 or
            receipt.get("input_sha256") != input_sha or receipt.get("kind") != "radar_transaction"):
        raise StoreError("RECEIPT_IDENTITY_MISMATCH")
    hashes = receipt.get("file_sha256")
    if not isinstance(hashes, dict) or not hashes or any(
            not allowed_write(p) or not isinstance(h, str) or not HASH.fullmatch(h) for p, h in hashes.items()):
        raise StoreError("RECEIPT_HASHES_INVALID")
    readback = store.read_documents(commit, [*hashes, path])
    if readback.get(path) != receipt:
        raise StoreError("RECEIPT_READBACK_MISMATCH")
    verify_readback({"file_sha256": hashes}, readback)
    return {"verified": True, "commit_sha": commit, "receipt_path": path,
            "scan_id": receipt["scan_id"], "new_job_count": receipt["new_job_count"],
            "files_verified": len(hashes) + 1, "persistence_enabled": True,
            "editorial_execution_enabled": False, "publication_enabled": False}


def persist_snapshot(store, fetch_result, *, now, max_attempts=4):
    """Recompute after every conflict; reuse the fetched input, never an old write plan."""
    if now.tzinfo is None or now.utcoffset() is None:
        raise StoreError("NOW_MUST_BE_TIMEZONE_AWARE")
    if not 1 <= max_attempts <= 8:
        raise StoreError("INVALID_RETRY_BUDGET")
    fetched = copy.deepcopy(fetch_result)
    if not any(x.get("ok") for x in fetched.get("source_statuses", [])):
        raise StoreError("NO_SOURCE_SUCCEEDED")
    stamp = utc_iso(now)
    input_sha = sha256({"observed_at": stamp, "fetch": fetched})
    receipt_path = PREFIX + "state/radar/receipts/txn-" + input_sha[:24] + ".json"
    for attempt in range(1, max_attempts + 1):
        head, documents = store.read_snapshot(receipt_path)
        _oid(head)
        receipt = documents.get(receipt_path)
        if receipt is not None:
            origin = store.origin_commit(head, receipt_path)
            result = _verify_receipt(store, origin, receipt_path, receipt, input_sha)
            return {**result, "replayed": True, "attempts": attempt}
        validate_snapshot(documents)
        previous_stamp = documents.get(PREFIX + "state/radar/current.json", {}).get("observed_at")
        if previous_stamp and datetime.fromisoformat(previous_stamp.replace("Z", "+00:00")) > now:
            raise StoreError("NEWER_RADAR_ALREADY_PERSISTED")
        plan = plan_snapshot(fetched, documents, now=now)
        validate_plan(plan, documents)
        receipt = {"schema_version": 1, "project": "ttittulares-v2", "kind": "radar_transaction",
                   "input_sha256": input_sha, "observed_at": stamp, "base_commit": head,
                   "scan_id": plan["scan_id"], "file_sha256": plan["file_sha256"],
                   "new_job_count": plan["new_job_count"], "publication_enabled": False}
        writes = {**plan["writes"], receipt_path: receipt}
        try:
            commit = store.commit(head, writes, "TTiTTulares V2: persistir radar " + receipt_path.rsplit("/", 1)[1][:-5])
        except (Conflict, UncertainCommit):
            continue
        result = _verify_receipt(store, commit, receipt_path, receipt, input_sha)
        return {**result, "replayed": False, "attempts": attempt}
    # A final read reconciles a successful-but-lost response on the last attempt.
    head, documents = store.read_snapshot(receipt_path)
    if receipt_path in documents:
        result = _verify_receipt(store, store.origin_commit(head, receipt_path), receipt_path,
                                 documents[receipt_path], input_sha)
        return {**result, "replayed": True, "attempts": max_attempts}
    raise StoreError("SNAPSHOT_RETRY_BUDGET_EXHAUSTED")


def main():
    parser = argparse.ArgumentParser(description="One isolated V2 radar pass; no scheduling or editorial execution")
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--persist", action="store_true", help="Explicitly allow one V2 GitHub state transaction")
    parser.add_argument("--verify-replay", action="store_true", help="Repeat the exact transaction input and verify no second commit")
    args = parser.parse_args()
    if args.verify_replay and not args.persist:
        parser.error("--verify-replay requires --persist")
    now = datetime.now(timezone.utc)
    fetched = fetch_all_sources(now=now)
    if not args.persist:
        print(encode({"fetch_metrics": fetched["metrics"], "persistence_enabled": False,
                      "publication_enabled": False}))
        return
    store = GitHubStore(os.environ.get("GITHUB_TOKEN"))
    result = persist_snapshot(store, fetched, now=now)
    if args.verify_replay:
        replay = persist_snapshot(store, fetched, now=now)
        if not replay["replayed"] or replay["commit_sha"] != result["commit_sha"]:
            raise StoreError("LIVE_REPLAY_VERIFICATION_FAILED")
        result["replay_verified"] = True
    print(encode({**result, "fetch_metrics": fetched["metrics"]}))


if __name__ == "__main__":
    try:
        main()
    except StoreError as exc:
        raise SystemExit(str(exc)) from None
