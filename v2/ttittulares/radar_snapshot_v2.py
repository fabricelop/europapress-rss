#!/usr/bin/env python3
"""Read-only fetch -> ingest -> durable snapshot plan. No Git or browser writes.

The caller must load every V2 news/job document at one pinned Git commit.
An empty mapping means a genuinely empty V2 store, never a failed read.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from .radar_ingest_v2 import ingest_scan
from .source_catalog_v2 import load_catalog
from .source_fetch_v2 import fetch_all_sources
from .selection_v1_parity_v2 import existing_story

PREFIX = "v2/ttittulares/"
BRANCH = "feature/ttactualidad-v2-clean"
EVENT_ID = re.compile(r"ttn2-[a-f0-9]{24}\Z")
TERMINAL = {"published", "dismissed", "deleted", "archived"}
ACTIVE = {"claimed", "send_intent", "awaiting_response", "capture_recovery",
          "captured", "validating", "persisting"}


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


def sha256(value):
    return hashlib.sha256(encode(value).encode("utf-8")).hexdigest()


def _event_path(event_id):
    if not EVENT_ID.fullmatch(event_id):
        raise ValueError("INVALID_V2_EVENT_ID")
    return PREFIX + "news/" + event_id + ".json"


def _job_path(event_id, revision):
    _event_path(event_id)
    if type(revision) is not int or revision < 1:
        raise ValueError("INVALID_REVISION")
    return PREFIX + f"jobs/editorial/{event_id}-r{revision}-editorial.json"


def _authorities(documents):
    news, jobs = {}, {}
    for path, doc in documents.items():
        if not path.startswith((PREFIX + "news/", PREFIX + "jobs/editorial/")):
            continue
        if doc.get("project") != "ttittulares-v2" or doc.get("schema_version") != 1:
            raise ValueError("AUTHORITY_PROJECT_MISMATCH")
        event_id = doc["event_id"]
        if path.startswith(PREFIX + "news/"):
            if path != _event_path(event_id):
                raise ValueError("NEWS_PATH_IDENTITY_MISMATCH")
            news[event_id] = copy.deepcopy(doc)
        else:
            if (path != _job_path(event_id, doc["revision"]) or
                    doc["job_id"] + ".json" != path.rsplit("/", 1)[1]):
                raise ValueError("JOB_PATH_IDENTITY_MISMATCH")
            jobs[doc["job_id"]] = copy.deepcopy(doc)
    for job in jobs.values():
        event = news.get(job["event_id"])
        if not event or not any(ref["revision"] == job["revision"] and
                                ref["editorial_job_id"] == job["job_id"]
                                for ref in event["revision_refs"]):
            raise ValueError("ORPHAN_EDITORIAL_JOB")
    return news, jobs


def _synchronise(previous, index, news):
    """Discard stale radar activity in favour of exact authoritative event state."""
    previous = copy.deepcopy(previous or {})
    index = copy.deepcopy(index or {"schema_version": 1, "project": "ttittulares-v2", "items": {}})
    if index.get("project") != "ttittulares-v2":
        raise ValueError("NEWS_INDEX_PROJECT_MISMATCH")
    previous.setdefault("items", {})
    if not isinstance(previous["items"], dict):
        raise ValueError("RADAR_ITEMS_MUST_BE_MAPPING")
    index.setdefault("items", {})
    for event_id, event in news.items():
        identity = event["identity"]
        item = index["items"].setdefault(event_id, {"event_id": event_id})
        item.update({
            "canonical_title": identity["canonical_title"],
            "aliases": identity.get("aliases", []),
            "current_revision": event["current_revision"], "status": event["status"],
            "terminal_status": event["status"] if event["status"] in TERMINAL else None,
            "editorial_created": True, "revision_refs": copy.deepcopy(event["revision_refs"]),
            "first_seen_at": identity["first_seen_at"], "last_seen_at": identity["last_seen_at"],
        })
        # READY must reach the material-update path, never match a stale eligible candidate.
        if event_id in previous["items"]:
            previous["items"][event_id]["status"] = event["status"]
        update = previous.get("material_updates", {}).get(event_id)
        if update and (event["status"] != "ready" or
                       update.get("base_revision") != event["current_revision"]):
            previous["material_updates"].pop(event_id, None)
    return previous, index


def _new_job(event, stamp):
    event_id, revision = event["event_id"], event["revision"]
    return {
        "schema_version": 1, "project": "ttittulares-v2",
        "job_id": f"{event_id}-r{revision}-editorial", "event_id": event_id,
        "revision": revision, "status": "pending", "phase": "queued",
        "priority": "material_update" if revision > 1 else "automatic",
        "requested_at": event["eligible_at"], "updated_at": stamp,
        # No fictional prompt hash: the future worker freezes the actual prompt before send_intent.
        "prompt": None,
        "attempts": {"claim_count": 0, "safe_preflight_failures": 0, "submission_count": 0,
                     "max_safe_preflight_attempts": 3, "history": []},
        "lease": None, "send_intent": None, "session": None,
        "capture": None, "result": None, "problem": None,
    }


def _new_event(candidate, item, existing, stamp):
    event = copy.deepcopy(existing or {})
    first = event.get("identity", {}).get("first_seen_at", candidate["first_seen_at"])
    title = candidate["canonical_title"]
    event.update({
        "schema_version": 1, "project": "ttittulares-v2", "event_id": candidate["event_id"],
        "current_revision": candidate["revision"], "status": "editorial_pending",
        "identity": {
            "canonical_fact": title, "canonical_title": title,
            "aliases": list(item.get("aliases", [])), "first_seen_at": first,
            "last_seen_at": candidate["last_seen_at"],
            "dedupe_keys": [{"kind": "headline_fingerprint", "value_sha256": sha256(title)}],
        },
        "source_summary": {
            "general_family_count": candidate["source_count"], "general_family_threshold": 4,
            "sport_source_count": candidate.get("sport_source_count", 0),
            "discovery_source_count": candidate.get("discovery_source_count", 0),
        },
        "revision_refs": copy.deepcopy(item["revision_refs"]),
        "current_record_path": event.get("current_record_path"),
        "created_at": event.get("created_at", stamp), "updated_at": stamp,
    })
    # The previous READY reference belongs to the previous revision; do not imply rN is READY.
    event["current_record_path"] = None
    return event


def plan_snapshot(fetch_result, documents, *, now, catalog=None):
    """Build changed JSON documents against a COMPLETE, commit-pinned store.

    Jobs, READY records, images and decisions already present are never overwritten.
    The plan is serialisable, deterministic and has no external effects.
    """
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("NOW_MUST_BE_TIMEZONE_AWARE")
    if not isinstance(fetch_result.get("rows"), list) or not isinstance(fetch_result.get("source_statuses"), list):
        raise ValueError("INVALID_FETCH_RESULT")
    news, jobs = _authorities(documents)
    previous, index = _synchronise(documents.get(PREFIX + "state/radar/current.json"),
                                   documents.get(PREFIX + "state/news-index.json"), news)
    # V1 parity: check against previously selected/treated identities.
    known_editorial = copy.deepcopy(index["items"])
    result = ingest_scan(fetch_result["rows"], fetch_result["source_statuses"],
                         previous, index, now=now, catalog=catalog)
    radar, index = result["radar_state"], result["news_index"]
    stamp = radar["observed_at"]
    candidates = result["newly_eligible"] + result["material_updates_eligible"]
    writes = {}
    selected = []
    for candidate in candidates:
        event_id, revision = candidate["event_id"], candidate["revision"]
        duplicate_of = existing_story(candidate, known_editorial, now=now)
        if duplicate_of:
            # Preserve all original documents. Do not create a second job
            # for the same already selected or treated factual event.
            item = index["items"][event_id]
            item.update(status="archived", editorial_created=False,
                        revision_refs=[], duplicate_of=duplicate_of)
            if event_id in radar.get("items", {}):
                radar["items"][event_id]["status"] = "archived"
            continue
        existing = news.get(event_id)
        if existing and (existing["status"] in TERMINAL or revision <= existing["current_revision"]):
            raise ValueError("EVENT_REVISION_REGRESSION")
        job_path = _job_path(event_id, revision)
        if job_path in documents:
            raise ValueError("JOB_ALREADY_EXISTS_FOR_NEW_REVISION")
        job = _new_job(candidate, stamp)
        event = _new_event(candidate, index["items"][event_id], existing, stamp)
        jobs[job["job_id"]] = job
        news[event_id] = event
        writes[job_path] = job
        writes[_event_path(event_id)] = event
        selected.append(candidate)
        known_editorial[event_id] = index["items"][event_id]
    # Reflect authority in reconstructible projections, including terminal human decisions.
    for event_id, event in news.items():
        item = index["items"][event_id]
        item["status"] = event["status"]
        item["terminal_status"] = event["status"] if event["status"] in TERMINAL else None
        item["current_revision"] = event["current_revision"]
        item["revision_refs"] = copy.deepcopy(event["revision_refs"])
    queue_items = []
    for job in sorted(jobs.values(), key=lambda x: (x["requested_at"], x["job_id"])):
        event = news[job["event_id"]]
        if event["status"] in TERMINAL or job["revision"] != event["current_revision"]:
            continue
        queue_items.append({key: job[key] for key in
                            ("job_id", "event_id", "revision", "status", "priority", "requested_at")})
        queue_items[-1]["job_path"] = _job_path(job["event_id"], job["revision"])
    queue = {
        "schema_version": 1, "project": "ttittulares-v2", "queue_type": "editorial",
        "updated_at": stamp, "source_of_truth": "individual_job_files",
        "pending_count": sum(x["status"] == "pending" for x in queue_items),
        "active_count": sum(x["status"] in ACTIVE for x in queue_items), "items": queue_items,
    }
    # Full input hash prevents the core scan_id (time + URLs) colliding on changed titles/health.
    scan = {"schema_version": 1, "project": "ttittulares-v2", "observed_at": stamp,
            "fetch": copy.deepcopy(fetch_result), "radar": radar,
            "accepted_rows": result["accepted_rows"], "filtered": result["filtered"],
            "effects_enabled": False, "publication_enabled": False}
    scan_id = "scan-" + sha256(scan)[:24]
    scan_path = PREFIX + "state/radar/scans/" + scan_id + ".json"
    if scan_path in documents and documents[scan_path] != scan:
        raise ValueError("IMMUTABLE_SCAN_COLLISION")
    writes.update({
        scan_path: scan, PREFIX + "state/radar/current.json": radar,
        PREFIX + "state/radar/source-health.json": radar["source_health"],
        PREFIX + "state/news-index.json": index, PREFIX + "state/editorial-queue.json": queue,
    })
    changed = {path: doc for path, doc in writes.items() if documents.get(path) != doc}
    return {"branch": BRANCH, "scan_id": scan_id, "observed_at": stamp,
            "writes": changed, "file_sha256": {path: sha256(doc) for path, doc in changed.items()},
            "new_job_count": len(selected), "queue": queue, "metrics": radar["metrics"],
            "effects_enabled": False, "publication_enabled": False}


def verify_readback(plan, readback):
    """Only an exact readback of every planned document proves persistence."""
    for path, expected in plan["file_sha256"].items():
        if path not in readback or sha256(readback[path]) != expected:
            raise ValueError("SNAPSHOT_READBACK_MISMATCH")
    return True


def main():
    parser = argparse.ArgumentParser(description="Read-only V2 fetch/ingest/snapshot plan")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--live", action="store_true", help="GET all sources; never write GitHub")
    mode.add_argument("--input", help="Offline JSON containing fetch and optional documents/now")
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=10)
    args = parser.parse_args()
    if args.live:
        now = datetime.now(timezone.utc)
        print("TTN2_LIVE_FETCH_START", file=sys.stderr, flush=True)
        payload = {"fetch": fetch_all_sources(now=now, workers=args.workers, timeout=args.timeout)}
        print("TTN2_LIVE_FETCH_DONE=" + json.dumps(payload["fetch"]["metrics"]), file=sys.stderr, flush=True)
    else:
        payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
        now = datetime.fromisoformat(payload["now"].replace("Z", "+00:00"))
    print("TTN2_SNAPSHOT_PLAN_START", file=sys.stderr, flush=True)
    plan = plan_snapshot(payload["fetch"], payload.get("documents", {}), now=now)
    print("TTN2_SNAPSHOT_PLAN_DONE", file=sys.stderr, flush=True)
    print(encode({"mode": "preview", "scan_id": plan["scan_id"], "metrics": plan["metrics"],
                  "fetch_metrics": payload["fetch"].get("metrics", {}),
                  "source_statuses": payload["fetch"]["source_statuses"],
                  "planned_files": len(plan["writes"]), "new_job_count": plan["new_job_count"],
                  "persistence_enabled": False, "publication_enabled": False}))


if __name__ == "__main__":
    main()
