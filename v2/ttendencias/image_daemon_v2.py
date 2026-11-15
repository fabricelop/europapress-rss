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
from parallel_dispatch_v2 import WorkerPool, prepare_profiles

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


def run_forever(*, poll_seconds=90, max_jobs=0, workers=2):
    if not enabled():
        raise RuntimeError("V2_IMAGES_AUTO_DISABLED")
    api = editorial.module("persist_capture_github.py", "ttv2_images_auto_api")
    auth = api.token()
    completed = 0
    with exclusive_v2_lock(LOCK):
        profiles = prepare_profiles(worker.PROFILE, workers,
                                    source_running=worker.image_profile_pids)
        pool = WorkerPool(profiles, env_key="TT_V2_IMAGE_PROFILE",
                          logs_dir=editorial.ROOT / "image-parallel-logs")
        report("STARTED", completed=completed, workers=workers)
        try:
            while enabled():
                for done in pool.reap():
                    tid = done["trend_id"]
                    if done["exit_code"]:
                        report("IMAGE_RETRY_LATER", completed=completed, trend_id=tid,
                               revision=done["revision"], attempt=done["attempt"],
                               active_workers=len(pool.active),
                               reason="worker_exit_%d log=%s" % (done["exit_code"], done["log"]))
                    else:
                        completed += 1
                        report("COMPLETED", completed=completed, trend_id=tid,
                               active_workers=len(pool.active))
                if max_jobs and completed >= max_jobs:
                    break
                try:
                    queue, _ = editorial.queue_read(api, auth)
                    history = worker.read_history(auth)
                    candidates = worker.ranked_candidates(queue, history)
                except Exception as exc:
                    report("WAIT_TOP30", completed=completed,
                           active_workers=len(pool.active), reason=str(exc)[:150])
                    time.sleep(12 if pool.active else poll_seconds)
                    continue
                started = 0
                for row in candidates:
                    if pool.available_slot() is None or (
                        max_jobs and completed + len(pool.active) >= max_jobs
                    ):
                        break
                    tid, rev = row["trend_id"], row["revision"]
                    if (tid, rev) in pool.busy_keys:
                        continue
                    attempt = worker.next_attempt(row)
                    if attempt is None:
                        continue
                    try:
                        launched = pool.spawn(pathlib.Path(__file__).with_name("image_worker_v2.py"),
                                              ["--run-one", "--trend-id", tid, "--revision", rev,
                                               "--attempt", attempt],
                                              trend_id=tid, revision=rev, attempt=attempt)
                    except (OSError, RuntimeError) as exc:
                        report("WORKER_LAUNCH_FAILED", trend_id=tid, revision=rev,
                               active_workers=len(pool.active), reason=str(exc)[:150])
                        break
                    if launched:
                        started += 1
                        report("WORKING", trend_id=tid, revision=rev, attempt=attempt,
                               active_workers=len(pool.active), workers=workers)
                if not pool.active and not started:
                    report("WAIT_NO_ELIGIBLE_IMAGE", completed=completed)
                time.sleep(12 if pool.active else poll_seconds)
        finally:
            if pool.active:
                report("DRAINING_ACTIVE_CHATS", completed=completed,
                       active_workers=len(pool.active))
                pool.wait_for_completion()
        report("STOPPED", completed=completed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--poll-seconds", type=int, default=90)
    parser.add_argument("--max-jobs", type=int, default=0)
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()
    if not 30 <= args.poll_seconds <= 600 or not 1 <= args.workers <= 6:
        parser.error("poll-seconds must be 30-600, workers must be 1-6")
    if not args.run:
        print("TT_V2_IMAGES_AUTO_ENABLED=" + ("YES" if enabled() else "NO"))
        worker.main()
        return
    run_forever(poll_seconds=args.poll_seconds, max_jobs=args.max_jobs,
                workers=args.workers)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AlreadyRunning) as exc:
        print("TT_V2_IMAGES_AUTO_ERROR=" + str(exc)[:200], file=sys.stderr)
        sys.exit(1)
