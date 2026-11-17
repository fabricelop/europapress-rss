#!/usr/bin/env python3
"""Persist one replaceable latest ImageGen raster per V2 trend in GitHub."""
from __future__ import annotations
import base64
import hashlib
import json
import re
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
TREND_ID=re.compile(r"^trv2-[a-f0-9]{24}$")
BLOB_SHA=re.compile(r"^[a-f0-9]{40}$")


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
    """Validate the exact current text/revision; a saved image is replaceable."""
    intake.validate_job(job)
    ledger=send("GET",LEDGER,auth)
    if not isinstance(ledger,dict):
        raise RuntimeError("V2_IMAGE_EDITORIAL_LEDGER_UNAVAILABLE")
    try:
        if ledger.get("encoding") == "base64" and ledger.get("content"):
            raw = base64.b64decode("".join(ledger["content"].split()), validate=True)
        elif ledger.get("encoding") == "none" and not ledger.get("content"):
            sha = ledger.get("sha")
            if not sha:
                raise RuntimeError("V2_IMAGE_EDITORIAL_LEDGER_SHA_MISSING")
            url = ("https://api.github.com/repos/" + REPO +
                   "/git/blobs/" + urllib.parse.quote(sha, safe=""))
            req = urllib.request.Request(url, headers={
                "Authorization": "Bearer " + auth,
                "Accept": "application/vnd.github+json",
                "User-Agent": "TTActualidadV2-ImageGen-GitHub"
            })
            with urllib.request.urlopen(req, timeout=90) as response:
                blob = json.load(response)
            if blob.get("encoding") != "base64":
                raise RuntimeError("V2_IMAGE_EDITORIAL_LEDGER_UNAVAILABLE")
            raw = base64.b64decode("".join(blob["content"].split()), validate=True)
        else:
            raise RuntimeError("V2_IMAGE_EDITORIAL_LEDGER_UNAVAILABLE")
        if git_blob_sha(raw) != ledger.get("sha"):
            raise RuntimeError("V2_IMAGE_EDITORIAL_LEDGER_SHA_MISMATCH")
        queue = json.loads(raw.decode("utf-8-sig"))
    except (KeyError, ValueError) as exc:
        raise RuntimeError("V2_IMAGE_EDITORIAL_LEDGER_CORRUPT") from exc
    if (queue.get("step")!="04_editorial_queue"
        or queue.get("effects_enabled") is not False):
        raise RuntimeError("V2_IMAGE_EDITORIAL_NOT_ISOLATED")
    row=(queue.get("items") or {}).get(job["trend_id"])
    if not row:raise RuntimeError("V2_IMAGE_TREND_NOT_FOUND")
    intake.validate_editorial(job,row)
    existing=(row.get("capture") or {}).get("image") or {}
    if (existing.get("status")=="saved" and existing.get("revision")==job["revision"]
            and _attempt_number(existing)>int(job.get("attempt",1))):
        raise RuntimeError("V2_IMAGE_STALE_ATTEMPT_NO_REPLACE")
    return row


def _attempt_number(image):
    if not isinstance(image,dict):
        return 0
    value=image.get("attempt")
    if type(value) is int and value>=1:
        return value
    parts=str(image.get("command_id") or "").split("-")
    if len(parts)>=2 and parts[-2].startswith("a") and parts[-2][1:].isdigit():
        return int(parts[-2][1:])
    return 0


def stable_image_path(trend_id):
    if not isinstance(trend_id,str) or not TREND_ID.fullmatch(trend_id):
        raise ValueError("V2_IMAGE_TREND_ID_INVALID")
    # One mutable file per trend. A new revision or retry replaces this raster.
    return PREFIX+trend_id+".image"


def save_original(job,raw,auth,*,send=request):
    """Replace the single latest raster for this trend and verify its bytes."""
    current_editorial(job,auth,send=send)
    meta=intake.raster_metadata(raw)
    path=stable_image_path(job["trend_id"])
    expected_blob=git_blob_sha(raw)
    previous=send("GET",path,auth)
    if previous and previous.get("sha")==expected_blob:
        status="already_saved"
    else:
        payload={"branch":BRANCH,"message":"v2: replace latest ImageGen "+
                 job["trend_id"]+" r"+str(job["revision"]),
                 "content":base64.b64encode(raw).decode("ascii")}
        if previous:
            old_sha=previous.get("sha")
            if not isinstance(old_sha,str) or not BLOB_SHA.fullmatch(old_sha):
                raise RuntimeError("V2_IMAGE_GITHUB_EXISTING_RASTER_CONFLICT")
            payload["sha"]=old_sha
        uploaded=send("PUT",path,auth,payload)
        if ((uploaded or {}).get("content") or {}).get("sha")!=expected_blob:
            raise RuntimeError("V2_IMAGE_GITHUB_WRITE_UNVERIFIED")
        if not (uploaded or {}).get("commit",{}).get("sha"):
            raise RuntimeError("V2_IMAGE_GITHUB_COMMIT_MISSING")
        status="replaced" if previous else "saved"
    confirmed=send("GET",path,auth)
    if not confirmed or confirmed.get("sha")!=expected_blob:
        raise RuntimeError("V2_IMAGE_GITHUB_READBACK_FAILED")
    return {"status":status,"trend_id":job["trend_id"],
            "revision":job["revision"],"attempt":job.get("attempt",1),
            "sha256":meta["sha256"],"path":path,"mime":meta["mime"],
            "width":meta["width"],"height":meta["height"],
            "command_id":job["command_id"],"backend":"github_v1_style"}


def cleanup_superseded_images(trend_id,keep_path,auth,*,send=request):
    """Delete legacy revision/hash-named rasters after the latest receipt is verified."""
    if not isinstance(trend_id,str) or not TREND_ID.fullmatch(trend_id):
        raise ValueError("V2_IMAGE_TREND_ID_INVALID")
    expected=stable_image_path(trend_id)
    if keep_path!=expected:
        raise ValueError("V2_IMAGE_KEEP_PATH_INVALID")
    listing=send("GET",PREFIX.rstrip("/"),auth)
    if listing is None:
        return 0
    if not isinstance(listing,list):
        raise RuntimeError("V2_IMAGE_LEGACY_LISTING_INVALID")
    deleted=0
    legacy_prefix=PREFIX+trend_id+"-r"
    for entry in listing:
        path=entry.get("path") if isinstance(entry,dict) else None
        if not isinstance(path,str) or path==keep_path or not path.startswith(legacy_prefix):
            continue
        sha=entry.get("sha")
        if not isinstance(sha,str) or not BLOB_SHA.fullmatch(sha):
            raise RuntimeError("V2_IMAGE_LEGACY_BLOB_SHA_INVALID")
        send("DELETE",path,auth,{"message":"v2: remove superseded image for "+trend_id,
                                 "sha":sha,"branch":BRANCH})
        deleted+=1
    return deleted
