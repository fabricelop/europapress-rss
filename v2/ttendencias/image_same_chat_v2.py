#!/usr/bin/env python3
"""V2-only ImageGen in the ALREADY OPEN verified editorial ChatGPT tab.

Never opens a second conversation, never touches V1, never publishes, and
never retries an uncertain prompt. Original raster must reach private R2/D1
before the caller closes its single Chrome session.
"""
from __future__ import annotations
import base64
import json
import os
import pathlib
import subprocess
import time
import urllib.error
import urllib.request
try:
    from . import image_intake_v2 as intake
    from . import image_job_v2 as jobs
except ImportError:
    import image_intake_v2 as intake
    import image_job_v2 as jobs

READY_ENDPOINT="https://ttactualidad-v2-private-test.fabricelop.workers.dev/api/image-ingest-ready"
WAIT_SECONDS=300
COMPOSERS=("#prompt-textarea","[data-testid='prompt-textarea']","[contenteditable='true'][role='textbox']")

def private_secret(root):
    path=pathlib.Path(root)/"image-ingest-secret.dpapi"
    if not path.exists():raise RuntimeError("V2_IMAGE_UPLOAD_NOT_ENROLLED")
    ciphertext=path.read_text(encoding="utf-8-sig").strip()
    if not ciphertext or len(ciphertext)>8192:raise RuntimeError("V2_IMAGE_UPLOAD_TOKEN_INVALID")
    script=("$s=ConvertTo-SecureString ([Console]::In.ReadToEnd());"
            "$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);"
            "try{[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))}"
            "finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}")
    proc=subprocess.run(["powershell.exe","-NoProfile","-NonInteractive","-Command",script],
         input=ciphertext,text=True,capture_output=True,timeout=15,
         creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
    secret=proc.stdout.strip()
    if proc.returncode or len(secret)<32:raise RuntimeError("V2_IMAGE_UPLOAD_DPAPI_FAILED")
    return secret

def check_storage_ready(secret,*,send=None):
    request=urllib.request.Request(READY_ENDPOINT,
        headers={"X-TTV2-Image-Ingest":secret,"Accept":"application/json"},
        method="GET")
    if send is None:send=lambda r:urllib.request.urlopen(r,timeout=15)
    try:
        with send(request) as response:
            payload=json.loads(response.read(1024))
            if payload.get("ok") is not True or payload.get("storage")!="ready":
                raise RuntimeError("V2_IMAGE_STORAGE_NOT_READY")
    except (urllib.error.URLError,ValueError) as exc:
        raise RuntimeError("V2_IMAGE_STORAGE_NOT_READY") from exc
    return True

def probe(command):
    return """(async()=>{
      const cmd=__COMMAND__;
      const users=[...document.querySelectorAll('[data-user-message-bubble="true"]')];
      const turns=users.length?users:[...document.querySelectorAll('[data-message-author-role="user"]')];
      const last=turns[turns.length-1];
      if(!last||!String(last.innerText||last.textContent||'').includes(cmd))
        return {ready:false,reason:'wrong_image_job_or_conversation'};
      if(document.querySelector('[data-testid="stop-button"]'))
        return {ready:false,reason:'still_generating'};
      const images=[...document.querySelectorAll('img')].filter(img=>
        img.complete&&img.naturalWidth>=1024&&img.naturalHeight>=576
        &&Boolean(last.compareDocumentPosition(img)&Node.DOCUMENT_POSITION_FOLLOWING)
        &&!turns.some(u=>u.contains(img))
        &&!/avatar|icon|profile/i.test(String(img.alt||'')));
      if(images.length!==1)return {ready:false,reason:'not_one_complete_original'};
      const img=images[0];let response;
      try{response=await fetch(img.currentSrc||img.src,{credentials:'include'});}
      catch{return {ready:false,reason:'image_fetch_failed'};}
      if(!response.ok)return {ready:false,reason:'image_http_error'};
      const blob=await response.blob();
      if(!['image/png','image/jpeg','image/webp'].includes(blob.type)
         ||blob.size<100000||blob.size>8388608)return {ready:false,reason:'raster_mime_or_size'};
      const bytes=new Uint8Array(await blob.arrayBuffer());let binary='';
      for(let i=0;i<bytes.length;i+=32768)
        binary+=String.fromCharCode(...bytes.subarray(i,i+32768));
      return {ready:true,mime:blob.type,width:img.naturalWidth,height:img.naturalHeight,
              data:btoa(binary)};
    })()""".replace("__COMMAND__",json.dumps(command))

def last_user_text(page):
    return page.evaluate("""()=>{
      const users=[...document.querySelectorAll('[data-user-message-bubble="true"]')];
      const nodes=users.length?users:[...document.querySelectorAll('[data-message-author-role="user"]')];
      const last=nodes[nodes.length-1];
      return last?String(last.innerText||last.textContent||''):'';
    }""")

def original_from_same_page(page, job, *, timeout=WAIT_SECONDS, clock=time.monotonic, sleep=time.sleep):
    until=clock()+timeout
    reason="not_generated"
    while clock()<until:
        result=page.evaluate(probe(job["command_id"]))
        if result and result.get("ready"):
            raw=base64.b64decode(result["data"],validate=True)
            meta=intake.raster_metadata(raw)
            if (meta["mime"]!=result["mime"] or meta["width"]!=result["width"]
                    or meta["height"]!=result["height"]):
                raise RuntimeError("V2_IMAGE_BROWSER_RASTER_MISMATCH")
            return raw
        reason=str((result or {}).get("reason") or "probe_empty")
        if reason=="wrong_image_job_or_conversation":
            raise RuntimeError("V2_IMAGE_WRONG_CHAT_JOB")
        sleep(3)
    raise RuntimeError("V2_IMAGE_NOT_READY:"+reason)

def run(page,row,*,root,secret=None,storage_check=check_storage_ready,
        raster_get=original_from_same_page,upload=intake.upload):
    """Requires row just reread from GitHub after stage_capture was committed."""
    capture=row.get("capture") or {}
    if (row.get("status")!="captured_review" or
        row.get("revision")!=capture.get("revision") or
        page.url.split("?",1)[0].rstrip("/")!=str(capture.get("chat_url") or "").rstrip("/")):
        raise RuntimeError("V2_IMAGE_EDITORIAL_CHAT_NOT_VERIFIED")
    root=pathlib.Path(root)
    if secret is None:secret=private_secret(root)
    # Fail closed before asking ImageGen when R2/D1 or the secret is unavailable.
    storage_check(secret)
    job,status=jobs.stage(root/"image-jobs",row)
    intake.validate_editorial(job,row)
    receipts=root/"image-receipts"
    receipts.mkdir(parents=True,exist_ok=True)
    receipt=receipts/(job["command_id"]+".json")
    if receipt.exists():
        saved=json.loads(receipt.read_text(encoding="utf-8"))
        if saved.get("sha256") and saved.get("trend_id")==job["trend_id"] and saved.get("revision")==job["revision"]:
            return saved
        raise RuntimeError("V2_IMAGE_RECEIPT_CONFLICT")
    intent=receipts/(job["command_id"]+".intent.json")
    last=last_user_text(page)
    if job["command_id"] not in last:
        # Editorial identity must remain the last user message of this exact chat.
        if (job["trend_id"] not in last or
            ("Revisión: "+str(job["revision"])) not in last):
            raise RuntimeError("V2_IMAGE_EDITORIAL_TURN_CHANGED")
        if intent.exists():
            raise RuntimeError("V2_IMAGE_SEND_UNCERTAIN_NO_RESEND")
        if page.locator("[data-testid='stop-button']").count():
            raise RuntimeError("V2_IMAGE_EDITORIAL_STILL_GENERATING")
        composer=None
        for selector in COMPOSERS:
            node=page.locator(selector).first
            if node.count() and node.is_visible() and node.is_enabled():
                composer=node;break
        if composer is None:raise RuntimeError("V2_IMAGE_COMPOSER_UNAVAILABLE")
        # Durable intent MUST precede Enter, even if the process is killed.
        with intent.open("x",encoding="utf-8") as handle:
            json.dump({"command_id":job["command_id"],"trend_id":job["trend_id"],
                       "revision":job["revision"],"status":"send_uncertain_no_replay"},handle)
        composer.fill(job["prompt"])
        composer.press("Enter")
    raw=raster_get(page,job)
    intake.persist_original(root/"image-originals",job,raw)
    saved=upload(job,raw,secret)
    if saved.get("status") not in ("saved","already_saved"):
        raise RuntimeError("V2_IMAGE_REMOTE_RECEIPT_INVALID")
    saved["command_id"]=job["command_id"]
    temp=receipt.with_suffix(".json.tmp")
    temp.write_text(json.dumps(saved,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    temp.replace(receipt)
    return saved
