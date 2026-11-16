"""Recover exactly the user-supplied Alcaraz reply. No browser or new submission."""
import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import json
import os
from pathlib import Path
import secrets

from .editorial_contract_v2 import parse_record, validate_record
from .editorial_state_v2 import EditorialService, EditorialGitHubStore, job_path, PREFIX

EVENT = "ttn2-0e0e7c7ebd494a7a753590d9"
JOB = EVENT + "-r1-editorial"
COMMAND = "news-bfc6017515a34ca09d010afdd74a1d96"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    envelope = json.loads((Path(__file__).parent / "recoveries/alcaraz-user-capture.json").read_text(encoding="utf-8"))
    payload = envelope["payload"]
    if (envelope.get("job_id") != JOB or payload.get("event_id") != EVENT
        or payload.get("revision") != 1 or payload.get("command_id") != COMMAND
        or envelope.get("source") != "user_supplied_original_chat_reply"):
        raise RuntimeError("RECOVERY_INPUT_IDENTITY_MISMATCH")
    recovered_at = datetime.fromisoformat(envelope["recovered_at"].replace("Z", "+00:00"))
    now = datetime.now(timezone.utc)
    if recovered_at.tzinfo is None or not timedelta(0) <= now - recovered_at <= timedelta(hours=24):
        raise RuntimeError("RECOVERY_INPUT_NOT_CURRENT")
    reply = "TTN2_EDITORIAL_BEGIN\n" + json.dumps(payload, ensure_ascii=False, indent=2) + "\nTTN2_EDITORIAL_END"
    answer_hash = hashlib.sha256(reply.encode("utf-8")).hexdigest()
    store = EditorialGitHubStore(os.environ["GITHUB_TOKEN"])
    head, docs = store.read_editorial_snapshot()
    job, event = docs[job_path(JOB)], docs[PREFIX + "news/" + EVENT + ".json"]
    if (job.get("send_intent") or {}).get("command_id") != COMMAND:
        raise RuntimeError("RECOVERY_LIVE_ATTEMPT_CHANGED")
    path = PREFIX + "records/" + EVENT + "/r1.json"
    if path in docs:
        if (job.get("capture") or {}).get("answer_sha256") != answer_hash:
            raise RuntimeError("RECOVERY_IMMUTABLE_CAPTURE_MISMATCH")
        record = validate_record(docs[path], event, job)
    else:
        record = parse_record(reply, event, job, COMMAND, recovered_at)
    evidence = envelope.get("cleanup_evidence") or {}
    proven = (envelope.get("cleanup_verified") is True and evidence.get("cleanup_verified") is True
              and evidence.get("job_id") == JOB and evidence.get("command_id") == COMMAND
              and evidence.get("sent") is True)
    checked = set(envelope.get("independently_checked_urls") or [])
    if len(checked) < 2 or not checked <= {row["article_url"] for row in record["source_evidence"]}:
        raise RuntimeError("RECOVERY_REVIEW_EVIDENCE_MISSING")
    if args.check or not proven:
        print(json.dumps({"validated": True, "cleanup_verified": proven,
              "writes": False, "tweet_characters": record["tweet"]["character_count"],
              "independent_sources": record["verified_source_count"]}))
        return
    worker = "user-capture-" + os.environ.get("GITHUB_RUN_ID", "manual")
    token = secrets.token_hex(32)
    service = EditorialService(store)
    service.recover_capture(JOB, worker, token, COMMAND, answer_hash,
        envelope["local_journal_id"], cleanup_verified=proven)
    result = service.complete(JOB, worker, token, record)
    if result.get("verified") is not True or result["job"]["status"] != "ready":
        raise RuntimeError("RECOVERY_READY_NOT_VERIFIED")
    actual = store.read_documents(result["commit_sha"], [path, job_path(JOB)])
    if actual[path] != record or actual[job_path(JOB)]["status"] != "ready":
        raise RuntimeError("RECOVERY_FINAL_READBACK_FAILED")
    print("TTN2_USER_CAPTURE_RECOVERED=" + json.dumps({
        "event_id": EVENT, "revision": 1, "command_id": COMMAND, "record_path": path,
        "commit_sha": result["commit_sha"], "verified": True,
        "tweet_characters": record["tweet"]["character_count"],
        "independent_sources": record["verified_source_count"],
        "new_chat_opened": False, "new_message_sent": False, "publication_enabled": False
    }))


if __name__ == "__main__":
    main()
