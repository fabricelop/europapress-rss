#!/usr/bin/env python3
"""V2-only ImageGen in the ALREADY OPEN verified editorial ChatGPT tab.

Never opens a second conversation, never touches V1, never publishes, and
never retries an uncertain prompt. Original raster is committed to the
isolated GitHub V2 branch before the caller closes its Chrome session.
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
    from . import image_github_v2 as github
except ImportError:
    import image_intake_v2 as intake
    import image_job_v2 as jobs
    import image_github_v2 as github

WAIT_SECONDS=300
COMPOSERS=("#prompt-textarea","[data-testid='prompt-textarea']","[contenteditable='true'][role='textbox']")

def probe(command):
    return """(async()=>{
      const cmd=__COMMAND__;
      // The UI may render older user turns as bubbles and the latest one
      // under the author-role wrapper. Read both in actual document order.
      const turns=[...document.querySelectorAll(
        '[data-user-message-bubble="true"],[data-message-author-role="user"]')];
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
      // Several UI previews may be rendered for one ImageGen command.
      // They are not a reason to block the trend; take the largest complete
      // raster after this specific command and bind only one.
      if(!images.length)return {ready:false,reason:'no_complete_original_yet'};
      images.sort((a,b)=>b.naturalWidth*b.naturalHeight-a.naturalWidth*a.naturalHeight);
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
    started=clock()
    until=started+timeout
    reason="not_generated"
    while clock()<until:
        # A new prompt must never silently continue in another conversation.
        if page.url.split("?",1)[0].rstrip("/")!=job["conversation_url"].rstrip("/"):
            raise RuntimeError("V2_IMAGE_CHAT_CHANGED")
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
            # Enter can return before ChatGPT inserts the new user bubble.
            # Wait briefly for DOM reconciliation without ever resending it.
            if clock()-started>=min(30,timeout/2):
                raise RuntimeError("V2_IMAGE_WRONG_CHAT_JOB")
        sleep(3)
    raise RuntimeError("V2_IMAGE_NOT_READY:"+reason)

def run(page,row,*,root,github_auth,raster_get=original_from_same_page,
        upload=github.save_original,editorial_preflight=github.current_editorial):
    """Requires row just reread from GitHub after stage_capture was committed."""
    capture=row.get("capture") or {}
    if (row.get("status")!="captured_review" or
        row.get("revision")!=capture.get("revision") or
        page.url.split("?",1)[0].rstrip("/")!=str(capture.get("chat_url") or "").rstrip("/")):
        raise RuntimeError("V2_IMAGE_EDITORIAL_CHAT_NOT_VERIFIED")
    root=pathlib.Path(root)
    if not isinstance(github_auth,str) or len(github_auth)<10:
        raise RuntimeError("V2_IMAGE_GITHUB_AUTH_MISSING")
    job,status=jobs.stage(root/"image-jobs",row)
    intake.validate_editorial(job,row)
    # Same branch, same token already used to persist the editorial reply.
    # Read the authoritative V2 queue immediately before sending ImageGen.
    editorial_preflight(job,github_auth)
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
    saved=upload(job,raw,github_auth)
    if saved.get("status") not in ("saved","already_saved"):
        raise RuntimeError("V2_IMAGE_REMOTE_RECEIPT_INVALID")
    saved["command_id"]=job["command_id"]
    temp=receipt.with_suffix(".json.tmp")
    temp.write_text(json.dumps(saved,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    temp.replace(receipt)
    return saved
