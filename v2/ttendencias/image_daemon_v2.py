#!/usr/bin/env python3
"""Independent V2 image loop. NEVER locks the editorial consumer or Chrome."""
import argparse
import json
import pathlib
import sys
import time
from datetime import datetime, timezone

import editorial_run_v2 as editorial
import image_worker_v2 as worker
from process_lock_v2 import exclusive_v2_lock, AlreadyRunning

FLAG = editorial.ROOT / "auto-images-v2.enabled"
LOCK = editorial.ROOT / "image_batch_v2.lock"
STATUS = editorial.ROOT / "image-daemon-status.json"


def enabled():
    try:
        return FLAG.read_text(encoding="utf-8-sig").strip() == "TT_V2_AUTO_IMAGES_ENABLED=YES"
    except FileNotFoundError:
        return False


def report(state, **details):
    value = {"service": "ttactualidad-v2-images", "at": datetime.now(timezone.utc).isoformat(),
             "state": state, "publication_allowed": False, **details}
    editorial.store(STATUS, value)
    print("TT_V2_IMAGES_AUTO_STATUS=" + json.dumps(value, ensure_ascii=False), flush=True)


def run_forever(*, poll_seconds=90, max_jobs=0):
    if not enabled():
        raise RuntimeError("V2_IMAGES_AUTO_DISABLED")
    api = editorial.module("persist_capture_github.py", "ttv2_images_auto_api")
    auth = api.token()
    completed = 0
    with exclusive_v2_lock(LOCK):
        report("STARTED", completed=completed)
        while enabled():
            if max_jobs and completed >= max_jobs:
                break
            if worker.image_profile_pids():
                report("WAIT_IMAGE_CHROME_ONLY", completed=completed)
                time.sleep(poll_seconds)
                continue
            try:
                queue, _ = editorial.queue_read(api, auth)
                history = worker.read_history(auth)
                row, attempt = worker.pick_next(queue, history)
            except Exception as exc:
                report("WAIT_TOP30", completed=completed, reason=str(exc)[:150])
                time.sleep(poll_seconds)
                continue
            if row is None:
                report("WAIT_NO_ELIGIBLE_IMAGE", completed=completed)
                time.sleep(poll_seconds)
                continue
            tid = row["trend_id"]
            report("WORKING", trend_id=tid, revision=row["revision"], attempt=attempt)
            try:
                worker.run_one(row, attempt, api=api, auth=auth)
                completed += 1
                report("COMPLETED", completed=completed, trend_id=tid)
            except Exception as exc:
                # A failed raster does not block editorial or any lower rank.
                report("IMAGE_RETRY_LATER", completed=completed,
                       trend_id=tid, reason=str(exc)[:150])
            time.sleep(3)
        report("STOPPED", completed=completed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--poll-seconds", type=int, default=90)
    parser.add_argument("--max-jobs", type=int, default=0)
    args = parser.parse_args()
    if not 30 <= args.poll_seconds <= 600:
        parser.error("poll-seconds must be between 30 and 600")
    if not args.run:
        print("TT_V2_IMAGES_AUTO_ENABLED=" + ("YES" if enabled() else "NO"))
        worker.main()
        return
    run_forever(poll_seconds=args.poll_seconds, max_jobs=args.max_jobs)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AlreadyRunning) as exc:
        print("TT_V2_IMAGES_AUTO_ERROR=" + str(exc)[:200], file=sys.stderr)
        sys.exit(1)
