"""Three-slot editorial authority, fenced leases and immutable READY transactions.

No browser, publication or V1 writes. Raw lease tokens and conversations stay local.
Every mutating method rereads the fixed branch and uses server-side Git CAS.
"""
from __future__ import annotations

import base64
import copy
import hashlib
import json
import re
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request

from .radar_snapshot_v2 import PREFIX, BRANCH, ACTIVE, TERMINAL, encode, sha256, _authorities
from .radar_store_v2 import GitHubStore, StoreError, Conflict, UncertainCommit, REPOSITORY, _oid

INDEX = PREFIX + "state/news-index.json"
QUEUE = PREFIX + "state/editorial-queue.json"
RECORD = re.compile(r"v2/ttittulares/records/ttn2-[a-f0-9]{24}/r[1-9][0-9]*\.json\Z")
AUTHORITY = re.compile(r"v2/ttittulares/(?:news/ttn2-[a-f0-9]{24}|jobs/editorial/ttn2-[a-f0-9]{24}-r[1-9][0-9]*-editorial)\.json\Z")
DECISION = re.compile(r"v2/ttittulares/decisions/ttn2-[a-f0-9]{24}/dcn2-[a-f0-9]{24}\.json\Z")
HASH = re.compile(r"[a-f0-9]{64}\Z")
JOB = re.compile(r"(ttn2-[a-f0-9]{24})-r([1-9][0-9]*)-editorial\Z")
SAFE_ID = re.compile(r"[A-Za-z0-9_.-]{1,128}\Z")
MAX_WORKERS = 3

def _pending_order(job):
    # A requested URGENTE runs in the next free slot; existing leases are
    # never preempted and FIFO remains stable within the priority band.
    return (0 if job["priority"] == "urgent" else 1, _time(job["requested_at"]), job["job_id"])


class EditorialError(StoreError):
    pass


def utcnow():
    return datetime.now(timezone.utc)


def _time(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError()
        return parsed.astimezone(timezone.utc)
    except (AttributeError, TypeError, ValueError):
        raise EditorialError("INVALID_EDITORIAL_TIMESTAMP") from None


def _stamp(value):
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise EditorialError("NOW_MUST_BE_TIMEZONE_AWARE")
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _secret(value):
    if not isinstance(value, str) or not 24 <= len(value) <= 512:
        raise EditorialError("INVALID_PRIVATE_LEASE_TOKEN")
    return hashlib.sha256(value.encode()).hexdigest()


def job_path(job_id):
    if not isinstance(job_id, str) or not JOB.fullmatch(job_id):
        raise EditorialError("INVALID_EDITORIAL_JOB_ID")
    return PREFIX + "jobs/editorial/" + job_id + ".json"


def record_path(job):
    job_path(job["job_id"])
    return PREFIX + f"records/{job['event_id']}/r{job['revision']}.json"


@lru_cache(maxsize=1)
def _validators():
    from jsonschema import Draft202012Validator, FormatChecker
    schema = json.loads((Path(__file__).parent / "schemas/contract.schema.json").read_text(encoding="utf-8"))
    return {kind: Draft202012Validator({"$ref": "#/$defs/" + kind, "$defs": schema["$defs"]},
                                      format_checker=FormatChecker()) for kind in
            ("news_event", "editorial_job", "editorial_record", "queue_index", "decision_event")}


def _schema(kind, doc):
    if not _validators()[kind].is_valid(doc):
        raise EditorialError("EDITORIAL_SCHEMA_INVALID_" + kind.upper())


def allowed(path, *, write=False):
    return path in (INDEX, QUEUE) or bool(AUTHORITY.fullmatch(path) or RECORD.fullmatch(path) or
                                         (not write and DECISION.fullmatch(path)))


class EditorialGitHubStore(GitHubStore):
    """Separate scope: reuse pinned/hash-checked Git reads, never weaken radar writes."""

    def __init__(self, token, **kwargs):
        super().__init__(token, **kwargs)
        self._editorial_blob_cache = {}

    def _http_raw(self, commit, path):
        _oid(commit)
        if not allowed(path):
            raise EditorialError("EDITORIAL_RAW_PATH_OUTSIDE_SCOPE")
        req = Request("https://raw.githubusercontent.com/" + REPOSITORY + "/" + commit + "/" + quote(path, safe="/"),
                      headers={"User-Agent": "TTiTTulares-V2-Editorial", "Accept": "application/json"})
        try:
            with self._opener.open(req, timeout=60) as response:
                raw = response.read(16_000_001)
        except (HTTPError, URLError, TimeoutError, ConnectionError, OSError):
            raise EditorialError("EDITORIAL_PINNED_READ_FAILED") from None
        if len(raw) > 16_000_000:
            raise EditorialError("EDITORIAL_DOCUMENT_TOO_LARGE")
        return raw

    def _blob_json(self, entry, commit=None, path=None):
        key = (entry.get("sha"), path, entry.get("mode"), entry.get("type"))
        if key not in self._editorial_blob_cache:
            doc = super()._blob_json(entry, commit, path)
            if len(self._editorial_blob_cache) > 1024:
                self._editorial_blob_cache.clear()
            self._editorial_blob_cache[key] = copy.deepcopy(doc)
        return copy.deepcopy(self._editorial_blob_cache[key])

    def read_editorial_snapshot(self):
        head = self.head()
        inventory = self.inventory(head)
        paths = [path for path, entry in inventory.items() if entry.get("type") != "tree" and allowed(path)]
        if INDEX not in paths or QUEUE not in paths:
            raise EditorialError("EDITORIAL_INDEX_MISSING")
        return head, self.read_documents(head, paths)

    def commit(self, expected_head, writes, message):
        _oid(expected_head)
        if not writes or any(not allowed(path, write=True) for path in writes):
            raise EditorialError("EDITORIAL_COMMIT_PATH_OUTSIDE_SCOPE")
        additions = [{"path": p, "contents": base64.b64encode(encode(doc).encode()).decode("ascii")}
                     for p, doc in sorted(writes.items())]
        result = self._request("POST", "/graphql", {
            "query": "mutation($input:CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid}}}",
            "variables": {"input": {"branch": {"repositoryNameWithOwner": REPOSITORY, "branchName": BRANCH},
                                    "expectedHeadOid": expected_head, "message": {"headline": message},
                                    "fileChanges": {"additions": additions}}}})
        if result.get("errors"):
            if self.head() != expected_head:
                raise Conflict("EDITORIAL_HEAD_CHANGED")
            raise EditorialError("EDITORIAL_COMMIT_REJECTED")
        try:
            return _oid(result["data"]["createCommitOnBranch"]["commit"]["oid"])
        except (KeyError, TypeError):
            raise UncertainCommit("EDITORIAL_COMMIT_RESPONSE_UNCERTAIN") from None


def _snapshot(docs):
    news, jobs = _authorities(docs)
    for event in news.values():
        _schema("news_event", event)
    for job in jobs.values():
        _schema("editorial_job", job)
        _time(job["requested_at"])
    if (INDEX not in docs or QUEUE not in docs or docs[INDEX].get("project") != "ttittulares-v2" or
            docs[INDEX].get("updated_at") != docs[QUEUE].get("updated_at")):
        raise EditorialError("EDITORIAL_PROJECTION_INCONSISTENT")
    _schema("queue_index", docs[QUEUE])
    # Never silently work on an index that has lost an authoritative event/job.
    for event_id, item in docs[INDEX].get("items", {}).items():
        if item.get("editorial_created") and event_id not in news:
            raise EditorialError("EDITORIAL_EVENT_MISSING")
    for event in news.values():
        for ref in event["revision_refs"]:
            if ref["editorial_job_id"] not in jobs:
                raise EditorialError("EDITORIAL_JOB_MISSING")
    for path, decision in docs.items():
        if DECISION.fullmatch(path):
            _schema("decision_event", decision)
    return news, jobs


def _blocked(event, job, docs):
    if event["status"] in TERMINAL or event["current_revision"] != job["revision"]:
        return True
    decisions = [doc for path, doc in docs.items() if DECISION.fullmatch(path) and
                 doc.get("event_id") == job["event_id"] and doc.get("revision") == job["revision"]]
    if decisions:
        latest = max(decisions, key=lambda x: (_time(x["occurred_at"]), x["decision_id"]))
        if latest["action"] in {"dismiss", "delete", "mark_published", "request_rework", "archive"}:
            return True
    return False


def _projections(docs, news, jobs, writes):
    index = copy.deepcopy(docs[INDEX])
    for event_id, event in news.items():
        if event_id not in index["items"]:
            raise EditorialError("EDITORIAL_INDEX_EVENT_MISSING")
        index["items"][event_id].update(status=event["status"], current_revision=event["current_revision"],
            terminal_status=event["status"] if event["status"] in TERMINAL else None,
            revision_refs=copy.deepcopy(event["revision_refs"]))
    rows = []
    for job in sorted(jobs.values(), key=lambda x: (_time(x["requested_at"]), x["job_id"])):
        if news[job["event_id"]]["status"] in TERMINAL or news[job["event_id"]]["current_revision"] != job["revision"]:
            continue
        rows.append({**{k: job[k] for k in ("job_id", "event_id", "revision", "status", "priority", "requested_at")},
                     "job_path": job_path(job["job_id"])})
    queue = {"schema_version": 1, "project": "ttittulares-v2", "queue_type": "editorial",
             "updated_at": index["updated_at"], "source_of_truth": "individual_job_files",
             "pending_count": sum(x["status"] == "pending" for x in rows),
             "active_count": sum(x["status"] in ACTIVE for x in rows), "items": rows}
    # updated_at remains the last radar capture, not the last editorial heartbeat.
    writes.update({INDEX: index, QUEUE: queue})


def _problem(job, code, now, retry="manual_only"):
    job.update(status="problematic", phase="blocked", updated_at=_stamp(now), lease=None,
               problem={"code": code, "at": _stamp(now), "retry_mode": retry})


def _recover(docs, news, jobs, now, writes):
    for job in jobs.values():
        if job["status"] not in ACTIVE:
            continue
        event = news[job["event_id"]]
        if _blocked(event, job, docs):
            job.update(status="superseded" if event["current_revision"] != job["revision"] else "cancelled",
                       phase="done", lease=None, updated_at=_stamp(now))
        elif not job.get("lease") or _time(job["lease"]["expires_at"]) <= now:
            if job["status"] == "claimed" and job["send_intent"] is None:
                job["attempts"]["safe_preflight_failures"] += 1
                job["attempts"]["history"].append({"attempt_no": job["attempts"]["claim_count"],
                    "command_id": "", "at": _stamp(now), "outcome": "preflight_failed"})
                if job["attempts"]["safe_preflight_failures"] < job["attempts"]["max_safe_preflight_attempts"]:
                    job.update(status="pending", phase="queued", lease=None, updated_at=_stamp(now))
                else:
                    _problem(job, "PREFLIGHT_RETRY_LIMIT", now)
            else:
                _problem(job, "EXPIRED_LEASE_AFTER_SEND_INTENT", now, "recover_same_chat")
        else:
            continue
        writes[job_path(job["job_id"])] = copy.deepcopy(job)


class EditorialService:
    """Call with a unique opaque worker_id and >=24 character PRIVATE lease token.

    prepare_send authorizes exactly one transmission only when its own fresh CAS
    succeeds. A replay or uncertain response returns send_authorized=False.
    Capture/READY may be safely retried with identical hashes; never send again.
    """

    def __init__(self, store, *, clock=utcnow, lease_seconds=600, max_attempts=5):
        if not 60 <= lease_seconds <= 1800 or not 1 <= max_attempts <= 8:
            raise EditorialError("INVALID_EDITORIAL_SERVICE_LIMIT")
        self.store, self.clock = store, clock
        self.lease_seconds, self.max_attempts = lease_seconds, max_attempts

    def preview(self):
        head, docs = self.store.read_editorial_snapshot()
        news, jobs = _snapshot(docs)
        now = self.clock()
        _stamp(now)
        pending = [j for j in jobs.values() if j["status"] == "pending" and not _blocked(news[j["event_id"]], j, docs)]
        pending.sort(key=_pending_order)
        stale = [j for j in jobs.values() if j["status"] in ACTIVE and
                 (_blocked(news[j["event_id"]], j, docs) or not j.get("lease") or
                  _time(j["lease"]["expires_at"]) <= now)]
        recovery = [j for j in jobs.values()
                    if j["status"] in {"problematic", "capture_recovery"}
                    and (j.get("problem") or {}).get("retry_mode") == "recover_same_chat"
                    and not _blocked(news[j["event_id"]], j, docs)]
        # A captured, confirmed response rejected by editorial validation stays
        # quarantined. It must never be resent or block different pending news.
        blocking = [j for j in recovery if not (
                    (j.get("send_intent") or {}).get("submission_state") == "confirmed"
                    and (j.get("capture") or {}).get("complete") is True)]
        plan = {"commit_sha": head, "pending_count": len(pending), "max_workers": MAX_WORKERS,
                "active_count": sum(j["status"] in ACTIVE for j in jobs.values()),
                "recovery_incident_count": len(recovery),
                "blocking_recovery_incident_count": len(blocking),
                "quarantined_incident_count": len(recovery) - len(blocking),
                "maintenance_needed": bool(stale), "stale_active_count": len(stale),
                "next_jobs": copy.deepcopy(pending[:MAX_WORKERS]), "effects_enabled": False}
        # A subclass may inspect this *already pinned* snapshot without making
        # hundreds of additional GitHub reads on every idle Windows poll.
        extension = getattr(self, "_preview_more", None)
        if extension is not None:
            plan.update(extension(docs, news, jobs, plan))
        return plan

    def _run(self, operation, *, worker_id, token, job_id=None, **data):
        if not SAFE_ID.fullmatch(str(worker_id)):
            raise EditorialError("INVALID_WORKER_ID")
        token_hash = _secret(token)
        if job_id is not None:
            job_path(job_id)
        uncertain = False
        for attempt in range(self.max_attempts + 1):
            now = self.clock()
            _stamp(now)
            head, docs = self.store.read_editorial_snapshot()
            news, jobs = _snapshot(docs)
            writes = {}
            if operation == "claim":
                _recover(docs, news, jobs, now, writes)
                owned = [j for j in jobs.values() if j.get("lease") and
                         j["lease"]["worker_id"] == worker_id and j["lease"]["token_sha256"] == token_hash]
                if owned:
                    job = owned[0]
                elif sum(j["status"] in ACTIVE for j in jobs.values()) < MAX_WORKERS:
                    candidates = [j for j in jobs.values() if j["status"] == "pending" and
                                  not _blocked(news[j["event_id"]], j, docs)]
                    candidates.sort(key=_pending_order)
                    job = candidates[0] if candidates else None
                    if job:
                        job.update(status="claimed", phase="browser_starting", updated_at=_stamp(now),
                            lease={"worker_id": worker_id, "token_sha256": token_hash, "started_at": _stamp(now),
                                   "heartbeat_at": _stamp(now), "expires_at": _stamp(now + timedelta(seconds=self.lease_seconds))},
                            problem=None)
                        job["attempts"]["claim_count"] += 1
                        writes[job_path(job["job_id"])] = copy.deepcopy(job)
                else:
                    job = None
            elif operation == "recover_capture":
                job = jobs.get(job_id)
                if not job:
                    raise EditorialError("EDITORIAL_JOB_NOT_FOUND")
                event = news[job["event_id"]]
                if _blocked(event, job, docs):
                    raise EditorialError("EDITORIAL_TERMINAL_OR_NEW_REVISION_WINS")
                if (data.get("cleanup_verified") is not True
                    or not HASH.fullmatch(str(data.get("answer_sha256", "")))
                    or not SAFE_ID.fullmatch(str(data.get("local_journal_id", "")))):
                    raise EditorialError("RECOVERY_CAPTURE_OR_CLEANUP_UNVERIFIED")
                intent = job.get("send_intent") or {}
                if (not intent or intent.get("command_id") != data.get("command_id")
                    or (job.get("session") or {}).get("private_journal_id") != data["local_journal_id"]):
                    raise EditorialError("RECOVERY_ORIGINAL_ATTEMPT_MISMATCH")
                capture = job.get("capture")
                if capture and capture["answer_sha256"] != data["answer_sha256"]:
                    raise EditorialError("IMMUTABLE_CAPTURE_MISMATCH")
                if job["status"] == "ready" and capture:
                    return self._result(head, docs, job, replayed=True)
                if job["status"] not in {"problematic", "capture_recovery", "captured", "validating", "persisting"}:
                    raise EditorialError("RECOVERY_JOB_NOT_QUARANTINED")
                if (job["status"] == "problematic"
                    and (job.get("problem") or {}).get("retry_mode") != "recover_same_chat"):
                    raise EditorialError("RECOVERY_REQUIRES_SAME_CHAT_INCIDENT")
                previous_lease = job.get("lease")
                same_owner = bool(previous_lease and previous_lease["worker_id"] == worker_id
                                  and previous_lease["token_sha256"] == token_hash)
                if previous_lease and _time(previous_lease["expires_at"]) > now and not same_owner:
                    raise EditorialError("EDITORIAL_LEASE_FENCED")
                if same_owner and capture and _time(previous_lease["expires_at"]) > now:
                    return self._result(head, docs, job, replayed=True)
                if sum(j["status"] in ACTIVE and j["job_id"] != job_id for j in jobs.values()) >= MAX_WORKERS:
                    raise EditorialError("RECOVERY_NO_WORKER_CAPACITY")
                job["lease"] = {"worker_id": worker_id, "token_sha256": token_hash, "started_at": _stamp(now),
                    "heartbeat_at": _stamp(now), "expires_at": _stamp(now + timedelta(seconds=self.lease_seconds))}
                job["attempts"]["claim_count"] += 1
                if not capture:
                    if job["attempts"]["submission_count"] < intent["attempt_no"]:
                        job["attempts"]["history"].append({"attempt_no": intent["attempt_no"],
                            "command_id": intent["command_id"], "at": _stamp(now), "outcome": "submitted"})
                    job["attempts"]["submission_count"] = max(job["attempts"]["submission_count"], intent["attempt_no"])
                    intent.update(submission_state="confirmed", submitted_at=intent.get("submitted_at") or _stamp(now))
                    job["capture"] = {"answer_sha256": data["answer_sha256"], "captured_at": _stamp(now),
                        "complete": True, "local_journal_id": data["local_journal_id"]}
                    job["attempts"]["history"].append({"attempt_no": intent["attempt_no"],
                        "command_id": intent["command_id"], "at": _stamp(now), "outcome": "captured"})
                job.update(status="persisting" if job["status"] == "persisting" else "captured",
                           phase="verifying", problem=None, updated_at=_stamp(now))
                event.update(status="editorial_in_progress", updated_at=_stamp(now))
                writes[job_path(job_id)] = copy.deepcopy(job)
                writes[PREFIX + "news/" + event["event_id"] + ".json"] = copy.deepcopy(event)
            else:
                job = jobs.get(job_id)
                if not job:
                    raise EditorialError("EDITORIAL_JOB_NOT_FOUND")
                event = news[job["event_id"]]
                if _blocked(event, job, docs):
                    raise EditorialError("EDITORIAL_TERMINAL_OR_NEW_REVISION_WINS")
                # READY replay has no live lease but is immutable and exact.
                if operation in {"finish", "persist_record"} and job["status"] == "ready":
                    if docs.get(record_path(job)) != data["record"]:
                        raise EditorialError("IMMUTABLE_READY_MISMATCH")
                    return self._result(head, docs, job, replayed=True)
                lease = job.get("lease")
                if not lease or lease["worker_id"] != worker_id or lease["token_sha256"] != token_hash:
                    raise EditorialError("EDITORIAL_LEASE_FENCED")
                if _time(lease["expires_at"]) <= now:
                    raise EditorialError("EDITORIAL_LEASE_EXPIRED")
                changed = self._apply(operation, job, event, docs, now, data)
                if changed:
                    writes[job_path(job_id)] = copy.deepcopy(job)
                    writes[PREFIX + "news/" + event["event_id"] + ".json"] = copy.deepcopy(event)
                    if data.get("record_write"):
                        path, record = data.pop("record_write")
                        writes[path] = record
            if writes:
                _projections(docs, news, jobs, writes)
                writes = {p: d for p, d in writes.items() if docs.get(p) != d}
            if not writes:
                return self._result(head, docs, job, replayed=True)
            if attempt == self.max_attempts:
                break
            for path, doc in writes.items():
                if path.startswith(PREFIX + "jobs/"):
                    _schema("editorial_job", doc)
                elif path.startswith(PREFIX + "news/"):
                    _schema("news_event", doc)
                elif RECORD.fullmatch(path):
                    _schema("editorial_record", doc)
                elif path == QUEUE:
                    _schema("queue_index", doc)
            try:
                commit = self.store.commit(head, writes, "TTiTTulares V2 editorial " + operation)
            except Conflict:
                continue
            except UncertainCommit:
                uncertain = True
                continue
            actual = self.store.read_documents(commit, writes)
            if set(actual) != set(writes) or any(actual[p] != d for p, d in writes.items()):
                raise EditorialError("EDITORIAL_READBACK_MISMATCH")
            merged = {**docs, **actual}
            return self._result(commit, merged, job, replayed=False,
                                send_authorized=operation == "prepare_send" and not uncertain)
        raise EditorialError("EDITORIAL_CAS_RETRY_BUDGET_EXHAUSTED")

    @staticmethod
    def _result(commit, docs, job, *, replayed=False, send_authorized=False):
        event = copy.deepcopy(docs.get(PREFIX + "news/" + job["event_id"] + ".json")) if job else None
        if event:
            event["source_context"] = copy.deepcopy(docs[INDEX]["items"][job["event_id"]])
        return {"verified": True, "commit_sha": commit, "job": copy.deepcopy(job),
                "event": event,
                "replayed": replayed, "send_authorized": send_authorized, "publication_enabled": False}

    def _apply(self, operation, job, event, docs, now, data):
        state = job["status"]
        if operation == "heartbeat":
            if state not in ACTIVE:
                raise EditorialError("EDITORIAL_JOB_NOT_ACTIVE")
            job["lease"].update(heartbeat_at=_stamp(now), expires_at=_stamp(now + timedelta(seconds=self.lease_seconds)))
        elif operation == "prepare_send":
            if not HASH.fullmatch(str(data["prompt_sha256"])) or not SAFE_ID.fullmatch(str(data["command_id"])):
                raise EditorialError("INVALID_SEND_INTENT")
            if job["send_intent"] is not None:
                intent = job["send_intent"]
                if intent["command_id"] != data["command_id"] or intent["prompt_sha256"] != data["prompt_sha256"]:
                    raise EditorialError("EDITORIAL_ALREADY_HAS_SEND_INTENT")
                return False
            if state != "claimed":
                raise EditorialError("EDITORIAL_NOT_CLAIMED")
            session = copy.deepcopy(data["session"])
            if not isinstance(session, dict) or not SAFE_ID.fullmatch(str(session.get("session_id", ""))) or not SAFE_ID.fullmatch(str(session.get("private_journal_id", ""))):
                raise EditorialError("INVALID_PRIVATE_SESSION_REFERENCE")
            job.update(status="send_intent", phase="sending", session=session,
                       prompt={"template_version": "news-editorial-v2", "prompt_sha256": data["prompt_sha256"]},
                       send_intent={"command_id": data["command_id"], "prompt_sha256": data["prompt_sha256"],
                                    "prepared_at": _stamp(now), "submission_state": "prepared",
                                    "attempt_no": job["attempts"]["submission_count"] + 1})
            event["status"] = "editorial_in_progress"
            for ref in event["revision_refs"]:
                if ref["revision"] == job["revision"]:
                    ref["status"] = "in_progress"
        elif operation == "submitted":
            conversation_hash = data.get("conversation_url_sha256")
            if conversation_hash is not None and not HASH.fullmatch(str(conversation_hash)):
                raise EditorialError("INVALID_CONFIRMED_CONVERSATION_HASH")
            if state == "awaiting_response":
                if conversation_hash is not None and job["session"]["conversation_url_sha256"] != conversation_hash:
                    raise EditorialError("CONFIRMED_CONVERSATION_HASH_CHANGED")
                return False
            if state != "send_intent" or not job["send_intent"]:
                raise EditorialError("EDITORIAL_NO_SEND_INTENT")
            job.update(status="awaiting_response", phase="awaiting_response")
            if conversation_hash is not None:
                job["session"]["conversation_url_sha256"] = conversation_hash
            job["send_intent"].update(submission_state="confirmed", submitted_at=_stamp(now))
            job["attempts"]["submission_count"] += 1
            job["attempts"]["history"].append({"attempt_no": job["send_intent"]["attempt_no"],
                "command_id": job["send_intent"]["command_id"], "at": _stamp(now), "outcome": "submitted"})
        elif operation == "captured":
            if not HASH.fullmatch(str(data["answer_sha256"])) or not SAFE_ID.fullmatch(str(data["local_journal_id"])):
                raise EditorialError("INVALID_CAPTURE_REFERENCE")
            if job["capture"]:
                if job["capture"]["answer_sha256"] != data["answer_sha256"]:
                    raise EditorialError("IMMUTABLE_CAPTURE_MISMATCH")
                return False
            if state != "awaiting_response":
                raise EditorialError("EDITORIAL_RESPONSE_NOT_AWAITED")
            job.update(status="captured", phase="verifying", capture={"answer_sha256": data["answer_sha256"],
                "captured_at": _stamp(now), "complete": True, "local_journal_id": data["local_journal_id"]})
            job["attempts"]["history"].append({"attempt_no": job["send_intent"]["attempt_no"],
                "command_id": job["send_intent"]["command_id"], "at": _stamp(now), "outcome": "captured"})
        elif operation == "persist_record":
            if state not in {"captured", "validating", "persisting"}:
                raise EditorialError("EDITORIAL_CAPTURE_REQUIRED")
            record = copy.deepcopy(data["record"])
            from .editorial_contract_v2 import validate_record
            validate_record(record, event, job)
            path = record_path(job)
            if path in docs:
                if docs[path] != record:
                    raise EditorialError("IMMUTABLE_READY_MISMATCH")
                return False
            # _run adds this new immutable record after the state transition.
            data["record_write"] = (path, record)
            job.update(status="persisting", phase="persisting")
        elif operation == "finish":
            path = record_path(job)
            if state != "persisting" or docs.get(path) != data["record"]:
                raise EditorialError("VERIFIED_IMMUTABLE_RECORD_REQUIRED")
            job.update(status="ready", phase="done", lease=None,
                result={"record_path": path, "record_sha256": sha256(data["record"]), "commit_sha": data["record_commit"]})
            event.update(status="ready", current_record_path=path, updated_at=_stamp(now))
            for ref in event["revision_refs"]:
                if ref["revision"] == job["revision"]:
                    ref.update(status="ready", record_path=path, completed_at=_stamp(now))
        elif operation == "fail":
            code = data["code"]
            if not isinstance(code, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]{2,100}", code):
                raise EditorialError("UNSAFE_EDITORIAL_ERROR_CODE")
            if data["safe_preflight"] and state == "claimed" and job["send_intent"] is None:
                job["attempts"]["safe_preflight_failures"] += 1
                job["attempts"]["history"].append({"attempt_no": job["attempts"]["claim_count"],
                    "command_id": "", "at": _stamp(now), "outcome": "preflight_failed"})
                if job["attempts"]["safe_preflight_failures"] < job["attempts"]["max_safe_preflight_attempts"]:
                    job.update(status="pending", phase="queued", lease=None, problem=None)
                else:
                    _problem(job, code, now)
            else:
                if job["send_intent"] and state == "send_intent":
                    job["send_intent"]["submission_state"] = "uncertain"
                if job["send_intent"]:
                    job["attempts"]["history"].append({"attempt_no": job["send_intent"]["attempt_no"],
                        "command_id": job["send_intent"]["command_id"], "at": _stamp(now),
                        "outcome": "uncertain" if state == "send_intent" else "failed_after_submit"})
                _problem(job, code, now, "recover_same_chat" if job["send_intent"] else "manual_only")
        else:
            raise EditorialError("UNKNOWN_EDITORIAL_OPERATION")
        job["updated_at"] = _stamp(now)
        return True

    def claim(self, worker_id, token):
        return self._run("claim", worker_id=worker_id, token=token)

    def heartbeat(self, job_id, worker_id, token):
        return self._run("heartbeat", job_id=job_id, worker_id=worker_id, token=token)

    def prepare_send(self, job_id, worker_id, token, prompt_sha256, command_id, session):
        return self._run("prepare_send", job_id=job_id, worker_id=worker_id, token=token,
                         prompt_sha256=prompt_sha256, command_id=command_id, session=session)

    def submitted(self, job_id, worker_id, token, conversation_url_sha256=None):
        return self._run("submitted", job_id=job_id, worker_id=worker_id, token=token,
                         conversation_url_sha256=conversation_url_sha256)

    def captured(self, job_id, worker_id, token, answer_sha256, local_journal_id):
        return self._run("captured", job_id=job_id, worker_id=worker_id, token=token,
                         answer_sha256=answer_sha256, local_journal_id=local_journal_id)

    def recover_capture(self, job_id, worker_id, token, command_id, answer_sha256,
                        local_journal_id, *, cleanup_verified):
        """Fence an exact user-recovered reply; never open ChatGPT or submit."""
        return self._run("recover_capture", job_id=job_id, worker_id=worker_id, token=token,
            command_id=command_id, answer_sha256=answer_sha256, local_journal_id=local_journal_id,
            cleanup_verified=cleanup_verified)

    def complete(self, job_id, worker_id, token, record):
        # Publish nothing until immutable record bytes have a verified original commit.
        self._run("persist_record", job_id=job_id, worker_id=worker_id, token=token, record=record)
        head, docs = self.store.read_editorial_snapshot()
        job = docs[job_path(job_id)]
        path = record_path(job)
        if docs.get(path) != record:
            raise EditorialError("EDITORIAL_RECORD_NOT_PERSISTED")
        origin = self.store.origin_commit(head, path)
        actual = self.store.read_documents(origin, [path])
        if actual.get(path) != record:
            raise EditorialError("EDITORIAL_RECORD_ORIGIN_MISMATCH")
        return self._run("finish", job_id=job_id, worker_id=worker_id, token=token,
                         record=record, record_commit=origin)

    def fail(self, job_id, worker_id, token, code, safe_preflight=False):
        return self._run("fail", job_id=job_id, worker_id=worker_id, token=token,
                         code=code, safe_preflight=safe_preflight)

