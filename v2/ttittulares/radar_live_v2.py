#!/usr/bin/env python3
"""Independent, observable news radar clock and scan.

The only writable files are the current radar and its source-health report on
the dedicated radar branch. Editorial/image commits cannot move this branch.
The normal feature-branch materializer separately creates editorial jobs.
"""
from __future__ import annotations

import argparse
import copy
import os
from datetime import datetime, timezone

from .radar_ingest_v2 import ingest_scan
from .radar_snapshot_v2 import BRANCH, PREFIX, encode, sha256
from .radar_store_v2 import (Conflict, GitHubStore, RADAR_LIVE_BRANCH,
                             StoreError, UncertainCommit)
from .source_fetch_v2 import fetch_all_sources

RADAR_PATH = PREFIX + "state/radar/current.json"
HEALTH_PATH = PREFIX + "state/radar/source-health.json"
SUMMARY_PATH = PREFIX + "state/radar/live-summary.json"
INDEX_PATH = PREFIX + "state/news-index.json"


def persist_live(fetch_result, radar_store, editorial_store, *, now, max_attempts=4):
    """Write an independently visible scan, never an editorial job or decision.

    A feature-branch change while we read its index is harmless: this writer
    never commits to that branch. The separate materializer is free to retry.
    """
    if now.tzinfo is None or now.utcoffset() is None:
        raise StoreError("NOW_MUST_BE_TIMEZONE_AWARE")
    if radar_store.branch != RADAR_LIVE_BRANCH or editorial_store.branch != BRANCH:
        raise StoreError("RADAR_LIVE_BRANCH_ISOLATION_REQUIRED")
    if not 1 <= max_attempts <= 8:
        raise StoreError("INVALID_RETRY_BUDGET")
    if not any(x.get("ok") for x in fetch_result.get("source_statuses", [])):
        raise StoreError("NO_SOURCE_SUCCEEDED")

    editorial_head = editorial_store.head()
    editorial_index = editorial_store.read_documents(editorial_head, [INDEX_PATH])[INDEX_PATH]
    if editorial_index.get("project") != "ttittulares-v2":
        raise StoreError("EDITORIAL_INDEX_PROJECT_MISMATCH")

    for attempt in range(1, max_attempts + 1):
        head = radar_store.head()
        previous = radar_store.read_documents(head, [RADAR_PATH])[RADAR_PATH]
        if previous.get("project") != "ttittulares-v2":
            raise StoreError("RADAR_PROJECT_MISMATCH")
        earlier = previous.get("observed_at")
        if earlier:
            earlier_time = datetime.fromisoformat(earlier.replace("Z", "+00:00"))
            if earlier_time >= now:
                # A delayed, older run never replaces a newer successful scan.
                return {"verified": True, "replayed": True, "observed_at": earlier,
                        "branch": RADAR_LIVE_BRANCH, "commit_sha": head,
                        "new_job_count": 0, "editorial_execution_enabled": False,
                        "publication_enabled": False, "attempts": attempt}
        plan = ingest_scan(fetch_result["rows"], fetch_result["source_statuses"],
                           copy.deepcopy(previous), copy.deepcopy(editorial_index), now=now)
        radar = plan["radar_state"]
        # The full radar is ~5 MB after several hours of monitoring. Serve this
        # compact, verified clock to the private UI; only the ingest engine
        # downloads the large historical state on the next pass.
        summary = {"schema_version": 1, "project": "ttittulares-v2",
                   "kind": "independent_radar_summary", "observed_at": radar["observed_at"],
                   "radar_sha256": sha256(radar), "source_health_sha256": sha256(radar["source_health"]),
                   "metrics": radar["metrics"],
                   "editorial_index_read_at": editorial_index.get("updated_at")}
        writes = {RADAR_PATH: radar, HEALTH_PATH: radar["source_health"], SUMMARY_PATH: summary}
        try:
            commit = radar_store.commit(head, writes,
                                        "TTiTTulares V2: barrido de radar independiente")
        except (Conflict, UncertainCommit):
            continue
        verified = radar_store.read_documents(commit, list(writes))
        if any(sha256(verified[key]) != sha256(doc) for key, doc in writes.items()):
            raise StoreError("LIVE_RADAR_READBACK_MISMATCH")
        return {"verified": True, "replayed": False, "observed_at": radar["observed_at"],
                "branch": RADAR_LIVE_BRANCH, "commit_sha": commit,
                "new_job_count": len(plan["newly_eligible"]) + len(plan["material_updates_eligible"]),
                "metrics": radar["metrics"], "editorial_execution_enabled": False,
                "publication_enabled": False, "attempts": attempt}
    raise StoreError("LIVE_RADAR_RETRY_BUDGET_EXHAUSTED")


def main():
    parser = argparse.ArgumentParser(description="Independent radar-only state; no editorial/browser")
    parser.add_argument("--live", action="store_true", required=True)
    parser.add_argument("--persist", action="store_true", required=True)
    args = parser.parse_args()
    now = datetime.now(timezone.utc)
    fetched = fetch_all_sources(now=now)
    token = os.environ.get("GITHUB_TOKEN")
    report = persist_live(fetched, GitHubStore(token, branch=RADAR_LIVE_BRANCH),
                          GitHubStore(token), now=now)
    print(encode({**report, "source_metrics": fetched["metrics"]}))


if __name__ == "__main__":
    try:
        main()
    except StoreError as exc:
        raise SystemExit(str(exc)) from None
