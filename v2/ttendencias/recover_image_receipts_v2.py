#!/usr/bin/env python3
"""Recover a verified ImageGen original already captured by a V2 image worker.

No Chrome, no ChatGPT request, no deletions and no editorial changes. A recovery
only applies to the exact latest failed command and editorial SHA, and only
after GitHub confirms the existing raster bytes by its immutable blob SHA.
Run while the dedicated V2 image daemon is drained/stopped.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
from datetime import datetime, timezone

import editorial_run_v2 as editorial
import image_github_v2 as github
import image_intake_v2 as intake
import image_job_v2 as jobs
import image_worker_v2 as worker


def recoverable(queue, root, *, now=None):
    """Find exact, already-generated originals without creating another job."""
    now = now or datetime.now(timezone.utc)
    root = pathlib.Path(root)
    results = []
    for row in (queue.get("items") or {}).values():
        if not isinstance(row, dict) or not worker.eligible(row):
            continue
        incident, cap = row.get("image_incident") or {}, row.get("capture") or {}
        command = incident.get("command_id")
        match = intake.COMMAND.fullmatch(command or "")
        if (not match or incident.get("project") != "ttendencias-v2"
                or incident.get("trend_id") != row["trend_id"]
                or incident.get("revision") != row["revision"]
                or incident.get("editorial_sha256") != cap.get("sha256")):
            continue
        progress = row.get("image_progress") or {}
        if progress.get("status") == "in_progress":
            try:
                deadline = datetime.fromisoformat(progress["expires_at"].replace("Z", "+00:00"))
                if deadline.tzinfo is None or deadline > now:
                    continue
            except (KeyError, TypeError, ValueError, AttributeError):
                continue
        attempt = int(match.group(3))
        journal = root / "image-only-journals" / (
            "%s-r%d-attempt-%03d.json" % (row["trend_id"], row["revision"], attempt))
        try:
            record = json.loads(journal.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeError):
            continue
        if (record.get("trend_id") != row["trend_id"]
                or record.get("revision") != row["revision"]
                or record.get("attempt") != attempt
                or record.get("command_id") != command
                or record.get("status") != "failed"):
            continue
        nonce = command.rsplit("-", 1)[-1]
        try:
            job = jobs.proposed_job(row, attempt=attempt, nonce=nonce)
            if job["command_id"] != command:
                continue
            job["conversation_url"] = record["image_chat_url"]
            intake.validate_job(job)
        except (KeyError, ValueError):
            continue
        originals = [path for ext in ("png", "jpg", "webp")
                     if (path := root / "image-originals" / (command + "." + ext)).is_file()]
        if len(originals) != 1:
            continue
        try:
            meta = intake.raster_metadata(originals[0].read_bytes())
        except Exception:
            # Pillow can raise OSError for damaged images. Keep such originals.
            continue
        if originals[0].suffix[1:] != {"image/png": "png", "image/jpeg": "jpg",
                                              "image/webp": "webp"}.get(meta["mime"]):
            continue
        results.append({"job": job, "path": originals[0], "meta": meta})
    return results


def recover_one(item, api, auth):
    """Bind only a matching existing original; do not regenerate or delete."""
    job = item["job"]
    queue, _ = editorial.queue_read(api, auth)
    row = (queue.get("items") or {}).get(job["trend_id"]) or {}
    cap, incident = row.get("capture") or {}, row.get("image_incident") or {}
    if (not worker.eligible(row) or row.get("revision") != job["revision"]
            or cap.get("sha256") != job["editorial_sha256"]
            or incident.get("command_id") != job["command_id"]
            or incident.get("editorial_sha256") != job["editorial_sha256"]):
        return "stale"
    progress = row.get("image_progress") or {}
    if progress.get("status") == "in_progress":
        try:
            expires = datetime.fromisoformat(progress["expires_at"].replace("Z", "+00:00"))
            if expires.tzinfo is None or expires > datetime.now(timezone.utc):
                return "active"
        except (KeyError, TypeError, AttributeError, ValueError):
            return "active"
    raw = item["path"].read_bytes()
    meta = intake.raster_metadata(raw)
    if meta["sha256"] != item["meta"]["sha256"]:
        return "changed_original"
    github.current_editorial(job, auth)
    ext = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"}[meta["mime"]]
    stored_path = ("v2/ttendencias/generated-images/" + job["trend_id"] +
                   "-r" + str(job["revision"]) + "-" + meta["sha256"][:24] + "." + ext)
    original = github.request("GET", stored_path, auth)
    if original and original.get("sha") != github.git_blob_sha(raw):
        return "conflicting_original"
    if original:
        saved = {"trend_id": job["trend_id"], "revision": job["revision"],
                 "command_id": job["command_id"], "sha256": meta["sha256"],
                 "path": stored_path, "mime": meta["mime"],
                 "backend": "github_v1_style"}
    else:
        # If GitHub no longer has the immutable original, upload the already
        # verified local bytes, never asking ChatGPT to generate them again.
        saved = github.save_original(job, raw, auth)
    receipt = worker.image_receipt(job, saved, job["conversation_url"])
    editorial.update_image_receipt(api, auth, job["trend_id"], job["revision"],
                                   job["editorial_sha256"], receipt)
    verified, _ = editorial.queue_read(api, auth)
    bound = (((verified["items"].get(job["trend_id"]) or {}).get("capture") or {}).get("image") or {})
    if (bound.get("status") != "saved" or bound.get("sha256") != meta["sha256"]):
        return "not_confirmed"
    return "saved"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="associate verified originals")
    args = parser.parse_args()
    api = editorial.module("persist_capture_github.py", "ttv2_image_recovery_api")
    auth = api.token()
    queue, _ = editorial.queue_read(api, auth)
    items = recoverable(queue, editorial.ROOT)
    print("TT_V2_IMAGE_RECOVERABLE=" + str(len(items)), flush=True)
    if not args.apply:
        print("TT_V2_IMAGE_RECOVERY_DRY_RUN=YES", flush=True)
        return
    if worker.image_profile_pids():
        raise RuntimeError("V2_IMAGE_RECOVERY_ACTIVE_CHROME_NO_WRITE")
    outcomes = []
    for item in items:
        try:
            outcome = recover_one(item, api, auth)
        except Exception:
            outcome = "failed"
        outcomes.append(outcome)
        print("TT_V2_IMAGE_RECOVERY=" + item["job"]["trend_id"] + ":" + outcome, flush=True)
        if outcome == "saved":
            worker.sync_image_progress(auth)
    print("TT_V2_IMAGE_RECOVERED=" + str(outcomes.count("saved")), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("TT_V2_IMAGE_RECOVERY_ERROR=" + type(exc).__name__, file=sys.stderr)
        sys.exit(1)
