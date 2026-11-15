#!/usr/bin/env python3
"""TTActualidad V2: validate and deliver a specific original ChatGPT ImageGen raster.

The caller is the isolated V2 Windows image receiver. This module neither opens
ChatGPT nor requests image generation. It NEVER uses V1 state or credentials.
"""
from __future__ import annotations
import hashlib
import io
import json
import os
import pathlib
import re
import urllib.error
import urllib.request

ID=re.compile(r"^trv2-[0-9a-f]{24}$")
COMMAND=re.compile(r"^v2-img-(trv2-[0-9a-f]{24})-r([1-9][0-9]*)-a([1-9][0-9]*)-[A-Za-z0-9_-]{8,60}$")
HEX=re.compile(r"^[0-9a-f]{64}$")
MIMES={"PNG":"image/png","JPEG":"image/jpeg","WEBP":"image/webp"}
MAX=8*1024*1024
MIN=100000
ENDPOINT="https://ttactualidad-v2-private-test.fabricelop.workers.dev/api/image-ingest"

def fingerprint(text):
    return hashlib.sha256(text.strip().encode("utf-8")).hexdigest()

def validate_job(job):
    if not isinstance(job,dict):raise ValueError("V2_IMAGE_JOB_NOT_OBJECT")
    tid=job.get("trend_id")
    rev=job.get("revision")
    command=job.get("command_id")
    digest=job.get("editorial_sha256")
    chat=job.get("conversation_url")
    match=COMMAND.fullmatch(command or "")
    if (not isinstance(tid,str) or not ID.fullmatch(tid)
        or type(rev) is not int or rev<1 or not match
        or match.group(1)!=tid or int(match.group(2))!=rev
        or not isinstance(digest,str) or not HEX.fullmatch(digest)
        or (chat is None and job.get("state")!="pending_imagegen")
        or (chat is not None and (not isinstance(chat,str) or not re.fullmatch(
          r"https://chatgpt\.com/(?:c/[a-f0-9-]{25,}|g/[A-Za-z0-9_-]+/c/[a-f0-9-]{25,})/?",chat)))):
        raise ValueError("V2_IMAGE_JOB_IDENTITY_INVALID")
    return job

def raster_metadata(raw, *, image_reader=None):
    if not isinstance(raw,bytes) or not MIN<=len(raw)<=MAX:
        raise ValueError("V2_IMAGE_ORIGINAL_SIZE_INVALID")
    if image_reader is None:
        from PIL import Image
        image_reader=Image
    with image_reader.open(io.BytesIO(raw)) as img:
        img.load()
        name=str(img.format or "").upper()
        mime=MIMES.get(name)
        width,height=img.size
        if not mime or width<1024 or height<576 or width>8192 or height>8192:
            raise ValueError("V2_IMAGE_ORIGINAL_FORMAT_OR_DIMENSIONS_INVALID")
    return {"mime":mime,"width":width,"height":height,
            "sha256":hashlib.sha256(raw).hexdigest(),"size":len(raw)}

def validate_editorial(job, row):
    validate_job(job)
    if (row.get("trend_id")!=job["trend_id"]
        or row.get("revision")!=job["revision"]
        or row.get("status") not in ("captured_review","ready")
        or fingerprint(((row.get("capture") or {}).get("answer") or row.get("explanation") or ""))!=job["editorial_sha256"]):
        raise ValueError("V2_IMAGE_EDITORIAL_CHANGED")
    return True

def upload(job,raw,secret,*,send=None):
    validate_job(job)
    if not isinstance(secret,str) or len(secret)<32:
        raise ValueError("V2_IMAGE_INGEST_SECRET_NOT_CONFIGURED")
    meta=raster_metadata(raw)
    headers={
        "X-TTV2-Image-Ingest":secret,"X-TTV2-Trend-Id":job["trend_id"],
        "X-TTV2-Revision":str(job["revision"]),"X-TTV2-Command-Id":job["command_id"],
        "X-TTV2-Editorial-Sha256":job["editorial_sha256"],
        "X-TTV2-Raster-Sha256":meta["sha256"],
        "X-TTV2-Width":str(meta["width"]),"X-TTV2-Height":str(meta["height"]),
        "Content-Type":meta["mime"],"Accept":"application/json",
    }
    request=urllib.request.Request(ENDPOINT,data=raw,headers=headers,method="POST")
    if send is None:
        send=lambda q: urllib.request.urlopen(q,timeout=60)
    try:
        with send(request) as response:
            receipt=json.loads(response.read(2048))
    except urllib.error.HTTPError as err:
        raise RuntimeError("V2_IMAGE_UPLOAD_HTTP_"+str(err.code)) from None
    if (receipt.get("ok") is not True
        or receipt.get("trend_id")!=job["trend_id"]
        or receipt.get("revision")!=job["revision"]
        or receipt.get("status") not in ("saved","already_saved")):
        raise RuntimeError("V2_IMAGE_UPLOAD_UNVERIFIED")
    return {"status":receipt["status"],"trend_id":job["trend_id"],
            "revision":job["revision"],"sha256":meta["sha256"],
            "width":meta["width"],"height":meta["height"]}

def persist_original(base,job,raw):
    validate_job(job)
    meta=raster_metadata(raw)
    root=pathlib.Path(base)
    root.mkdir(parents=True,exist_ok=True)
    path=root/(job["command_id"]+"."+MIMES_INVERSE[meta["mime"]])
    if path.exists():
        if hashlib.sha256(path.read_bytes()).hexdigest()!=meta["sha256"]:
            raise RuntimeError("V2_IMAGE_LOCAL_ORIGINAL_CONFLICT")
        return path
    with path.open("xb") as target:target.write(raw)
    return path

MIMES_INVERSE={"image/png":"png","image/jpeg":"jpg","image/webp":"webp"}
