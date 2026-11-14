#!/usr/bin/env python3
"""Persist original V2 ImageGen raster in GitHub exactly as V1 does.

The only source of truth for editorial identity is the isolated V2 queue.
No Cloudflare R2, D1, payments, V1 paths or publishing side effects.
"""
from __future__ import annotations
import base64
import hashlib
import json
import urllib.error
import urllib.parse
import urllib.request

try:
    from . import image_intake_v2 as intake
except ImportError:
    import image_intake_v2 as intake

REPO="fabricelop/europapress-rss"
BRANCH="feature/ttactualidad-v2-clean"
ROOT="v2/ttendencias"
LEDGER=ROOT+"/state/editorial-queue.json"
PREFIX=ROOT+"/generated-images/"
API="https://api.github.com/repos/"+REPO+"/contents/"
EXTENSIONS={"image/png":"png","image/jpeg":"jpg","image/webp":"webp"}

def request(method,path,auth,payload=None,*,opener=None):
    if not isinstance(auth,str) or len(auth)<10:
        raise RuntimeError("V2_IMAGE_GITHUB_AUTH_MISSING")
    if not path.startswith(ROOT+"/") or ".." in path or "?" in path:
        raise ValueError("V2_IMAGE_GITHUB_PATH_INVALID")
    url=API+urllib.parse.quote(path,safe="/")
    if method=="GET":
        url+="?ref="+urllib.parse.quote(BRANCH,safe="")
    body=json.dumps(payload,separators=(",",":")).encode("utf-8") if payload is not None else None
    req=urllib.request.Request(url,data=body,method=method,headers={
        "Authorization":"Bearer "+auth,
        "Accept":"application/vnd.github+json",
        "X-GitHub-Api-Version":"2022-11-28",
        "User-Agent":"TTActualidadV2-ImageGen-GitHub",
        **({"Content-Type":"application/json"} if body is not None else {})
    })
    if opener is None:opener=lambda r:urllib.request.urlopen(r,timeout=90)
    try:
        with opener(req) as response:
            return json.load(response)
    except urllib.error.HTTPError as err:
        if method=="GET" and err.code==404:return None
        if err.code in (409,412,422):
            raise RuntimeError("V2_IMAGE_GITHUB_CONFLICT_NO_REPLAY") from None
        raise RuntimeError("V2_IMAGE_GITHUB_HTTP_"+str(err.code)) from None

def git_blob_sha(raw):
    return hashlib.sha1(b"blob "+str(len(raw)).encode("ascii")+bytes([0])+raw).hexdigest()

def current_editorial(job,auth,*,send=request):
    intake.validate_job(job)
    ledger=send("GET",LEDGER,auth)
    if not isinstance(ledger,dict) or ledger.get("encoding")!="base64":
        raise RuntimeError("V2_IMAGE_EDITORIAL_LEDGER_UNAVAILABLE")
    try:
        queue=json.loads(base64.b64decode(ledger["content"],validate=True))
    except (KeyError,ValueError) as exc:
        raise RuntimeError("V2_IMAGE_EDITORIAL_LEDGER_CORRUPT") from exc
    if (queue.get("step")!="04_editorial_queue"
        or queue.get("effects_enabled") is not False):
        raise RuntimeError("V2_IMAGE_EDITORIAL_NOT_ISOLATED")
    row=(queue.get("items") or {}).get(job["trend_id"])
    if not row:raise RuntimeError("V2_IMAGE_TREND_NOT_FOUND")
    intake.validate_editorial(job,row)
    existing=(row.get("capture") or {}).get("image") or {}
    if existing.get("status")=="saved" and existing.get("command_id")!=job["command_id"]:
        raise RuntimeError("V2_IMAGE_REVISION_ALREADY_BOUND")
    return row

def save_original(job,raw,auth,*,send=request):
    """GitHub contents PUT with exact git-blob verification and idempotent replay."""
    current_editorial(job,auth,send=send)
    meta=intake.raster_metadata(raw)
    ext=EXTENSIONS[meta["mime"]]
    path=PREFIX+job["trend_id"]+"-r"+str(job["revision"])+"-"+meta["sha256"][:24]+"."+ext
    expected_blob=git_blob_sha(raw)
    previous=send("GET",path,auth)
    if previous:
        if previous.get("sha")!=expected_blob:
            raise RuntimeError("V2_IMAGE_GITHUB_EXISTING_RASTER_CONFLICT")
        status="already_saved"
    else:
        # Guard once. If it races with another writer, fail instead of replacing.
        payload={"branch":BRANCH,"message":"v2: original ImageGen "+
                 job["trend_id"]+" r"+str(job["revision"]),
                 "content":base64.b64encode(raw).decode("ascii")}
        uploaded=send("PUT",path,auth,payload)
        if ((uploaded or {}).get("content") or {}).get("sha")!=expected_blob:
            raise RuntimeError("V2_IMAGE_GITHUB_WRITE_UNVERIFIED")
        if not (uploaded or {}).get("commit",{}).get("sha"):
            raise RuntimeError("V2_IMAGE_GITHUB_COMMIT_MISSING")
        status="saved"
    confirmed=send("GET",path,auth)
    if not confirmed or confirmed.get("sha")!=expected_blob:
        raise RuntimeError("V2_IMAGE_GITHUB_READBACK_FAILED")
    return {"status":status,"trend_id":job["trend_id"],
            "revision":job["revision"],"sha256":meta["sha256"],
            "path":path,"mime":meta["mime"],"width":meta["width"],
            "height":meta["height"],"command_id":job["command_id"],
            "backend":"github_v1_style"}
