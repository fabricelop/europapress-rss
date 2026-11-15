#!/usr/bin/env python3
"""V2-only image delivery queue consumer; 1 explicitly requested job per run.

The Windows scheduled task can invoke --run --once. No implicit Top30 backfill,
no V1 changes, no automatic X posting or ChatGPT resend after uncertainty.
"""
from __future__ import annotations
import argparse
import json
import pathlib
import sys

import image_capture_v2 as receiver
import image_intake_v2 as intake

ROOT=receiver.ROOT
JOBS=ROOT/"image-jobs"
RECEIPTS=ROOT/"image-receipts"

def select_jobs():
    if not JOBS.exists():return []
    pending=[]
    for index in sorted(JOBS.glob("*.index.json")):
        job=json.loads(index.read_text(encoding="utf-8-sig"))
        intake.validate_job(job)
        if not index.name.startswith(job["trend_id"]+"-r"+str(job["revision"])+".index"):
            raise ValueError("V2_IMAGE_JOB_INDEX_IDENTITY_MISMATCH")
        file=JOBS/(job["command_id"]+".json")
        if not file.exists():raise RuntimeError("V2_IMAGE_JOB_ORIGINAL_MISSING")
        original=json.loads(file.read_text(encoding="utf-8-sig"))
        if original!=job:raise RuntimeError("V2_IMAGE_JOB_MUTATED")
        receipt=RECEIPTS/(job["command_id"]+".json")
        if receipt.exists():continue
        pending.append((file,RECEIPTS/(job["command_id"]+".intent.json")))
    return pending

def run_one(*,execute=False):
    jobs=select_jobs()
    print("TT_V2_IMAGE_PENDING="+str(len(jobs)),flush=True)
    if not jobs:return "no_jobs"
    path,intent=jobs[0]
    if not execute:return "would_run"
    receiver.run(path,generate=not intent.exists())
    print("TT_V2_IMAGE_ORIGINAL_PERSISTED=YES",flush=True)
    return "saved"

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--run",action="store_true")
    parser.add_argument("--once",action="store_true")
    args=parser.parse_args()
    result=run_one(execute=args.run)
    print("TT_V2_IMAGE_DELIVERY="+result,flush=True)

if __name__=="__main__":
    try:main()
    except Exception as exc:
        print("TT_V2_IMAGE_DELIVERY_ERROR="+str(exc)[:150],file=sys.stderr,flush=True)
        sys.exit(1)
