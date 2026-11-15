#!/usr/bin/env python3
"""Create immutable V2 ImageGen jobs only for explicit per-trend requests.

This is the V2 equivalent of V1 command-scoped ImageGen jobs. Nothing is
generated or published here; the separate V2 Chrome worker consumes the job.
"""
from __future__ import annotations
import argparse
import json
import pathlib
import secrets
import sys

from image_intake_v2 import validate_job, fingerprint

def proposed_job(row, *, attempt=1, nonce=None):
    if row.get("status") not in ("captured_review","ready"):
        raise ValueError("V2_IMAGE_EDITORIAL_NOT_CAPTURED")
    tid=row.get("trend_id")
    revision=row.get("revision")
    capture=row.get("capture") or {}
    answer=capture.get("answer")
    chat=capture.get("chat_url")
    if (not isinstance(answer,str) or not answer.strip() or
        capture.get("revision")!=revision or
        not isinstance(chat,str)):
        raise ValueError("V2_IMAGE_SOURCE_CAPTURE_INVALID")
    if type(attempt) is not int or not 1<=attempt<=99:
        raise ValueError("V2_IMAGE_ATTEMPT_INVALID")
    if nonce is None:nonce=secrets.token_hex(12)
    if not isinstance(nonce,str) or not 8<=len(nonce)<=60 or not all(ch.isalnum() or ch in "_-" for ch in nonce):
        raise ValueError("V2_IMAGE_NONCE_INVALID")
    command="v2-img-"+tid+"-r"+str(revision)+"-a"+str(attempt)+"-"+nonce
    brief=" ".join(answer.split())[:1800]
    # No headline/text painted in the image. One joke, not a noisy collage.
    prompt=("TT_V2_IMAGE_JOB_V1 "+command+" "+tid+" | "
            "Usa ImageGen AHORA. Genera UNA SOLA imagen GAG editorial original "
            "basada únicamente en el contexto facilitado, dibujo nítido y acabado "
            "de gran calidad, resolución al menos 1024px, composición limpia y "
            "una idea visual cómica que se entienda al instante. No hagas un collage "
            "ni incrustes titulares, hashtags, marcas de agua o texto ilegible. "
            "No inventes hechos ni presentes una situación satírica como fotografía real. "
            "No publiques en redes ni modifiques Github. "
            "Tendencia: "+str(row.get("name") or tid)+". "
            "Contexto editorial: "+brief)
    result={"version":1,"trend_id":tid,"revision":revision,"attempt":attempt,
            "command_id":command,"conversation_url":chat,
            "editorial_sha256":fingerprint(answer),"prompt":prompt,
            "state":"pending_imagegen"}
    validate_job(result)
    return result

def stage(directory,row,*,attempt=1):
    root=pathlib.Path(directory)
    root.mkdir(parents=True,exist_ok=True)
    tid,revision=row.get("trend_id"),row.get("revision")
    index=root/(tid+"-r"+str(revision)+".index.json")
    if index.exists():
        previous=json.loads(index.read_text(encoding="utf-8"))
        validate_job(previous)
        if previous["trend_id"]!=tid or previous["revision"]!=revision or previous["editorial_sha256"]!=fingerprint((row.get("capture") or {}).get("answer") or ""):
            raise ValueError("V2_IMAGE_INDEX_CONTEXT_CHANGED")
        return previous,"already_staged"
    job=proposed_job(row,attempt=attempt)
    path=root/(job["command_id"]+".json")
    with path.open("x",encoding="utf-8") as handle:json.dump(job,handle,ensure_ascii=False,indent=2)
    try:
        with index.open("x",encoding="utf-8") as handle:json.dump(job,handle,ensure_ascii=False,indent=2)
    except FileExistsError:
        path.unlink(missing_ok=True)
        raise ValueError("V2_IMAGE_INDEX_CONCURRENT_REQUEST")
    return job,"staged"

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--trend-id",required=True)
    parser.add_argument("--revision",type=int,required=True)
    parser.add_argument("--request",action="store_true")
    args=parser.parse_args()
    from editorial_run_v2 import queue_read,module,ROOT
    api=module("persist_capture_github.py","v2_image_jobs_github")
    q,_=queue_read(api,api.token())
    row=q["items"].get(args.trend_id)
    if not row or row.get("revision")!=args.revision:raise ValueError("V2_IMAGE_REVISION_NOT_CURRENT")
    if not args.request:
        planned=proposed_job(row,nonce="dryrun12345678")
        print("TT_V2_IMAGE_JOB_DRY_RUN="+planned["command_id"])
        return
    job,status=stage(ROOT/"image-jobs",row)
    print("TT_V2_IMAGE_JOB_STATE="+status)
    print("TT_V2_IMAGE_JOB_ID="+job["command_id"])
    print("TT_V2_IMAGE_PUBLISHED=NO")

if __name__=="__main__":
    try:main()
    except Exception as exc:
        print("TT_V2_IMAGE_JOB_ERROR="+str(exc)[:150],file=sys.stderr)
        sys.exit(1)
