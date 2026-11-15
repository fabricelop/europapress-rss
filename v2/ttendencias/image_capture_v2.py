#!/usr/bin/env python3
"""Recover only an already-generated ImageGen raster from its exact V2 ChatGPT job.

No generation, no resend, no V1 profiles, no publication. Runs on the isolated
Windows V2 profile when the editor is idle and an image job has been recorded.
"""
from __future__ import annotations
import argparse
import base64
import json
import os
import pathlib
import socket
import subprocess
import sys
import time
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

import editorial_run_v2 as editor
import image_intake_v2 as intake
from process_lock_v2 import exclusive_v2_lock

ROOT=editor.ROOT
LOCK=ROOT/"editorial_batch_v2.lock"
RECEIPTS=ROOT/"image-receipts"
ORIGINALS=ROOT/"image-originals"
STOP_TIMEOUT=90
# This expression is evaluated inside the *exact* ChatGPT conversation. A user
# bubble containing the scoped command must be the last user turn; only ONE real
# raster after the bubble may be captured.
def probe(command):
    return """(async()=>{
      const cmd=__COMMAND__;
      const bubbles=[...document.querySelectorAll('[data-user-message-bubble="true"]')];
      const users=bubbles.length?bubbles:[...document.querySelectorAll('[data-message-author-role="user"]')];
      const last=users[users.length-1];
      if(!last||!String(last.innerText||last.textContent||'').includes(cmd))
        return {ready:false,reason:'wrong_image_job_or_conversation'};
      if(document.querySelector('[data-testid="stop-button"]'))
        return {ready:false,reason:'still_generating'};
      const image=[...document.querySelectorAll('img')].filter(img=>
        img.complete&&img.naturalWidth>=1024&&img.naturalHeight>=576
        &&Boolean(last.compareDocumentPosition(img)&Node.DOCUMENT_POSITION_FOLLOWING)
        &&!users.some(u=>u.contains(img))
        &&!/avatar|icon|profile/i.test(String(img.alt||'')));
      if(image.length!==1)return {ready:false,reason:'not_one_complete_original'};
      const img=image[0];
      let response;
      try{response=await fetch(img.currentSrc||img.src,{credentials:'include'});}
      catch{return {ready:false,reason:'image_fetch_failed'};}
      if(!response.ok)return {ready:false,reason:'image_http_error'};
      const blob=await response.blob();
      if(!['image/png','image/jpeg','image/webp'].includes(blob.type)
         ||blob.size<100000||blob.size>8388608)
        return {ready:false,reason:'raster_mime_or_size'};
      const bytes=new Uint8Array(await blob.arrayBuffer());
      let binary='';
      for(let i=0;i<bytes.length;i+=32768)binary+=String.fromCharCode(...bytes.subarray(i,i+32768));
      return {ready:true,mime:blob.type,width:img.naturalWidth,height:img.naturalHeight,
              data:btoa(binary)};
    })()""".replace("__COMMAND__",json.dumps(command))

def private_secret():
    """Read a Windows user-DPAPI encrypted token, never from GitHub or stdout."""
    file=ROOT/"image-ingest-secret.dpapi"
    if not file.exists():raise RuntimeError("V2_IMAGE_UPLOAD_NOT_ENROLLED")
    data=file.read_text(encoding="utf-8-sig").strip()
    if not data or len(data)>8192:raise RuntimeError("V2_IMAGE_UPLOAD_TOKEN_INVALID")
    ps=("$s=ConvertTo-SecureString ([Console]::In.ReadToEnd());"
        "$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);"
        "try{[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))}"
        "finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}")
    p=subprocess.run(["powershell.exe","-NoProfile","-NonInteractive","-Command",ps],
                     input=data,text=True,capture_output=True,timeout=15,
                     creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
    secret=p.stdout.strip()
    if p.returncode or len(secret)<32:raise RuntimeError("V2_IMAGE_UPLOAD_DPAPI_FAILED")
    return secret

def exact_job(path):
    base=(ROOT/"image-jobs").resolve()
    file=pathlib.Path(path).resolve()
    if file.parent!=base or file.suffix.lower()!=".json":
        raise ValueError("V2_IMAGE_JOB_OUTSIDE_PRIVATE_DIRECTORY")
    job=json.loads(file.read_text(encoding="utf-8-sig"))
    intake.validate_job(job)
    if file.stem!=job["command_id"]:raise ValueError("V2_IMAGE_JOB_FILENAME_MISMATCH")
    return job

def fetch_raster(job, *, generate=False, intent_file=None):
    if editor.profile_pids():raise RuntimeError("V2_EDITOR_BROWSER_BUSY")
    if not editor.CHROME.exists():raise RuntimeError("V2_CHROME_MISSING")
    port=None
    with socket.socket() as sock:
        sock.bind(("127.0.0.1",0));port=sock.getsockname()[1]
    if port in (9223,9234):raise RuntimeError("V1_CDP_PORT_RESERVED")
    chrome_command=editor.module("chrome_command_v2.py","image_chrome_command_v2")
    visibility=editor.module("chrome_visibility_v2.py","image_visibility_v2")
    arguments=chrome_command.command(editor.CHROME,editor.PROFILE,port,headless=editor.HEADLESS,hidden=not editor.HEADLESS)
    proc=subprocess.Popen(arguments,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
          startupinfo=visibility.startupinfo_hidden() if not editor.HEADLESS else None,
          creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
    hider=None
    if not editor.HEADLESS:hider=visibility.V2WindowHider(editor.profile_pids).start()
    try:
        endpoint="http://127.0.0.1:"+str(port)
        with sync_playwright() as pw:
            for _ in range(40):
                try:
                    browser=pw.chromium.connect_over_cdp(endpoint,timeout=5000)
                    break
                except Exception:time.sleep(1)
            else:raise RuntimeError("V2_IMAGE_CDP_UNAVAILABLE")
            try:
                context=browser.contexts[0]
                page=next((p for p in context.pages if p.url==job["conversation_url"]),None)
                if page is None:
                    page=context.new_page()
                    page.goto(job["conversation_url"],wait_until="domcontentloaded",timeout=45000)
                if page.url.rstrip("/")!=job["conversation_url"].rstrip("/"):
                    raise RuntimeError("V2_IMAGE_CHAT_URL_CHANGED")
                if generate:
                    prompt=str(job.get("prompt") or "")
                    if not prompt.startswith("TT_V2_IMAGE_JOB_V1 "+job["command_id"]+" "):
                        raise RuntimeError("V2_IMAGE_PROMPT_CONTEXT_MISMATCH")
                    already=page.evaluate("""(cmd)=>{
                      const users=[...document.querySelectorAll('[data-user-message-bubble="true"]')];
                      return users.some(n=>String(n.innerText||n.textContent||'').includes(cmd));
                    }""",job["command_id"])
                    if not already:
                        if not intent_file:raise RuntimeError("V2_IMAGE_INTENT_PATH_REQUIRED")
                        if intent_file.exists():raise RuntimeError("V2_IMAGE_SEND_INTENT_UNCERTAIN_NO_RESEND")
                        composer=None
                        for selector in editor.COMPOSERS:
                            node=page.locator(selector).first
                            if node.count() and node.is_visible() and node.is_enabled():
                                composer=node;break
                        if composer is None:raise RuntimeError("V2_IMAGE_COMPOSER_UNAVAILABLE")
                        intent_file.write_text(json.dumps({"command_id":job["command_id"],
                          "trend_id":job["trend_id"],"revision":job["revision"],
                          "state":"send_intent_not_retriable"},sort_keys=True),encoding="utf-8")
                        composer.fill(prompt)
                        composer.press("Enter")
                until=time.monotonic()+STOP_TIMEOUT
                last_reason="no_raster"
                while time.monotonic()<until:
                    result=page.evaluate(probe(job["command_id"]))
                    if result and result.get("ready"):
                        encoded=result.get("data","")
                        raw=base64.b64decode(encoded,validate=True)
                        meta=intake.raster_metadata(raw)
                        if meta["mime"]!=result["mime"] or meta["width"]!=result["width"] or meta["height"]!=result["height"]:
                            raise RuntimeError("V2_IMAGE_BROWSER_RASTER_MISMATCH")
                        return raw
                    last_reason=str((result or {}).get("reason") or "probe_empty")
                    if last_reason=="wrong_image_job_or_conversation":
                        raise RuntimeError("V2_IMAGE_WRONG_CHAT_JOB")
                    time.sleep(3)
                raise RuntimeError("V2_IMAGE_NOT_READY:"+last_reason)
            finally:browser.close()
    finally:
        if hider:
            try:hider.stop()
            except Exception:pass
        if proc.poll() is None:
            proc.terminate()
            try:proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill();proc.wait(timeout=10)
        if editor.profile_pids():raise RuntimeError("V2_IMAGE_CHROME_NOT_CLOSED")

def run(jobfile, *, generate=False):
    job=exact_job(jobfile)
    RECEIPTS.mkdir(parents=True,exist_ok=True)
    receipt=RECEIPTS/(job["command_id"]+".json")
    if receipt.exists():
        record=json.loads(receipt.read_text(encoding="utf-8"))
        if record.get("trend_id")==job["trend_id"] and record.get("revision")==job["revision"] and record.get("status") in ("saved","already_saved"):
            print("TT_V2_IMAGE_ALREADY_SAVED=YES");return
        raise RuntimeError("V2_IMAGE_RECEIPT_CONFLICT")
    api=editor.module("persist_capture_github.py","v2_image_github")
    queue,_=editor.queue_read(api,api.token())
    row=queue["items"].get(job["trend_id"])
    if not row:intake.validate_job(job);raise RuntimeError("V2_IMAGE_EDITORIAL_NOT_FOUND")
    intake.validate_editorial(job,row)
    secret=private_secret()
    with exclusive_v2_lock(LOCK):
        raw=fetch_raster(job,generate=generate,intent_file=RECEIPTS/(job["command_id"]+".intent.json"))
        intake.persist_original(ORIGINALS,job,raw)
        saved=intake.upload(job,raw,secret)
        tmp=receipt.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(saved,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        tmp.replace(receipt)
    print("TT_V2_IMAGE_SAVED="+job["trend_id"]+":r"+str(job["revision"]))
    print("TT_V2_IMAGE_GENERATED_HERE=NO")

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--job",type=pathlib.Path,required=True)
    parser.add_argument("--run",action="store_true")
    parser.add_argument("--generate",action="store_true",help="Send scoped ImageGen prompt once, then capture original; never resend uncertain commands")
    args=parser.parse_args()
    job=exact_job(args.job)
    if not args.run:
        print("TT_V2_IMAGE_JOB_VALID=YES")
        print("TT_V2_IMAGE_AUTOMATIC_UPLOAD=DRY_RUN")
        return
    run(args.job,generate=args.generate)

if __name__=="__main__":
    try:main()
    except Exception as exc:
        print("TT_V2_IMAGE_CAPTURE_ERROR="+str(exc)[:120],file=sys.stderr)
        sys.exit(1)
