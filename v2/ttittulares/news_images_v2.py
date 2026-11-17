"""Independent news image consumer; one fresh owned chat per image, never a text chat."""
from __future__ import annotations
import argparse, hashlib, json, os, secrets, subprocess, sys, time, uuid
from pathlib import Path
from datetime import datetime, timezone
from .editorial_browser_v2 import ChromeJob, write_private, common
from .editorial_consumer_v2 import github_token, settings, error_code
from .news_workflow_v2 import NewsService, NewsStore, sync_controls, read_controls
from v2.ttendencias.image_same_chat_v2 import original_from_same_page
from v2.ttendencias.image_intake_v2 import raster_metadata

def image_prompt(record, command):
    identity=json.dumps({"event_id":record["event_id"],"revision":record["revision"],"command_id":command},ensure_ascii=False)
    return ("TTN2_IMAGE_JOB_V1 "+identity+"\nUsa ImageGen AHORA para generar UNA SOLA imagen original "
        "de mínimo 1024px de anchura, en este chat nuevo independiente. No abras el chat editorial ni "
        "reescribas la noticia. Estilo: cómic europeo editorial, escena narrativa única con protagonistas "
        "expresivos, acción reconocible, profundidad, luz y textura; una metáfora visual clara del hecho. "
        "Sin titulares, hashtags, logos, texto superpuesto, diagramas ni collage. En sucesos graves usa "
        "una escena contextual seria y respetuosa; nunca humor a costa de las víctimas. No publiques "
        "ni modifiques GitHub.\nNOTICIA CONTRASTADA:\n"+record["title"]+"\n"+record["factual_summary"]+
        "\n"+record["tweet"]["text"])

def run_one(service, config, *, browser_factory=ChromeJob, raster_get=original_from_same_page):
    run=uuid.uuid4().hex;worker="news-image-"+run;token=secrets.token_hex(32)
    claim=service.image("claim",worker_id=worker,token=token)
    if not claim.get("job"):return {"status":"idle","published":False}
    job,record=claim["job"],claim["record"]
    jid=job["job_id"];command="news-img-"+run
    journal={"job_id":jid,"command_id":command,"worker_id":worker,"lease_token":token,
             "sent":False,"intent_durable":False,"cleanup_verified":False}
    local=config["root"]/"image-journals"/(run+".json")
    browser=None;failure=None;raw=meta=None
    beat=lambda:service.image("heartbeat",worker_id=worker,token=token,job_id=jid)
    try:
        write_private(local,journal)
        browser=browser_factory(chrome=config["chrome"],seed=config["seed"],
            profile=config["root"]/"image-sessions"/run/"Profile")
        browser.open()
        prompt=image_prompt(record,command);digest=hashlib.sha256(prompt.encode()).hexdigest()
        result=service.image("prepare",worker_id=worker,token=token,job_id=jid,
            command_id=command,prompt_sha256=digest,session={"session_id":run,"private_journal_id":run,
            "conversation_url_sha256":hashlib.sha256(b"https://chatgpt.com/").hexdigest()})
        journal["intent_durable"]=True;write_private(local,journal)
        if result.get("send_authorized") is not True:raise RuntimeError("NEWS_IMAGE_UNCERTAIN_NO_RESEND")
        browser.send_once(prompt);journal["sent"]=True;write_private(local,journal)
        url=browser.confirm_submission(job["event_id"],job["revision"],command,beat)
        journal["chat_url"]=url;write_private(local,journal)
        service.image("submitted",worker_id=worker,token=token,job_id=jid)
        class HeartbeatPage:
            last_heartbeat=time.monotonic()
            @property
            def url(self):return browser.page.url
            def evaluate(self,script):
                if time.monotonic()-self.last_heartbeat>=45:
                    beat();self.last_heartbeat=time.monotonic()
                return browser.page.evaluate(script)
        raw=raster_get(HeartbeatPage(),{"conversation_url":url,"command_id":command},timeout=600)
        meta=raster_metadata(raw)
        original=config["root"]/"image-originals"/(run+".bin")
        original.parent.mkdir(parents=True,exist_ok=True);original.write_bytes(raw)
        journal.update(captured=True,raster_sha256=meta["sha256"],original_path=str(original))
        write_private(local,journal)
    except Exception as exc:
        failure=exc;journal["error_code"]=error_code(exc)
        if browser:journal["private_recovery_diagnostic"]=getattr(browser,"recovery_diagnostic",None)
        if "AUTH" in journal["error_code"]:
            (config["root"]/"images.enabled").write_text("TTN2_IMAGES_ENABLED=NO",encoding="utf-8")
    finally:
        if browser:
            try:
                # Keep the journal for deduplication, not this disposable
                # browser profile. ChromeJob removes it only after safe close.
                browser.close();journal["cleanup_verified"]=browser.cleanup_verified
            except Exception as exc:failure=failure or exc
        write_private(local,journal)
    if failure or not journal["cleanup_verified"]:
        code=error_code(failure) if failure else "NEWS_IMAGE_CLEANUP_UNVERIFIED"
        try:service.image("fail",worker_id=worker,token=token,job_id=jid,code=code,
            cleanup_verified=journal["cleanup_verified"])
        except Exception:journal["failure_persistence_unverified"]=True;write_private(local,journal)
        return {"status":"incident","job_id":jid,"code":code,"cleanup_verified":journal["cleanup_verified"],"published":False}
    # Persist only after verified browser cleanup; revalidate the current revision before association.
    beat()
    path,commit=service.store.save_raster(raw,job["event_id"],job["revision"],meta)
    asset={"schema_version":1,"project":"ttittulares-v2","media_id":"img2-"+hashlib.sha256((job["event_id"]+str(job["revision"])+meta["sha256"]).encode()).hexdigest()[:24],
        "event_id":job["event_id"],"revision":job["revision"],"editorial_sha256":job["editorial_sha256"],
        "image_job_id":jid,"command_id":command,"sha256":meta["sha256"],"mime":meta["mime"],
        "width":meta["width"],"height":meta["height"],"bytes":meta["size"],"asset_path":path,
        "origin":"chatgpt_images","verified":True,"created_at":datetime.now(timezone.utc).isoformat(),
        "alt":"Ilustración editorial: "+record["title"],"rights_status":"generated"}
    saved=service.image("save",worker_id=worker,token=token,job_id=jid,asset=asset,
        raster_commit=commit,cleanup_verified=True)
    journal.update(saved=True,commit_sha=saved["commit_sha"]);write_private(local,journal)
    return {"status":"saved","job_id":jid,"verified":True,"cleanup_verified":True,"published":False}

def enabled(root):
    try:return (root/"images.enabled").read_text(encoding="utf-8").strip()=="TTN2_IMAGES_ENABLED=YES"
    except FileNotFoundError:return False

def image_health(root, status):
    """Replace one private diagnostics snapshot; never log tokens or chat contents."""
    safe={"project":"ttittulares-v2","kind":"image_daemon_health",
          "checked_at":datetime.now(timezone.utc).isoformat(),**status}
    try:write_private(root/"image-daemon-status.json",safe)
    except OSError:pass  # An unwritable diagnostic must not abort an owned image job.

def check(service):
    """A read-only probe of image dispatch and the private control endpoint."""
    controls=read_controls(service.store._token)
    service.image_preferences=controls.get("preferences",[])
    service.image_retry_requests=[a for a in controls.get("actions",[]) if isinstance(a,dict) and a.get("action")=="retry_image"]
    return {"project":"ttittulares-v2","status":"ok",
            "image_preview":service.image_preview(),"controls_ok":True,"published":False}

def daemon(service,config):
    root=config["root"];pool={}
    health={"enabled":True,"pending_count":None,"active_count":None,
            "workers_running":0,"error_stage":None,"error_code":None,
            "last_worker_exit_code":None,"last_worker_completed_at":None,"last_spawned_at":None}
    with common("process_lock_v2").exclusive_v2_lock(root/"images.lock"):
        while enabled(root) or pool:
            for slot,child in list(pool.items()):
                exit_code=child.poll()
                if exit_code is not None:
                    del pool[slot]
                    health["last_worker_exit_code"]=exit_code
                    health["last_worker_completed_at"]=datetime.now(timezone.utc).isoformat()
            if enabled(root):
                try:
                    sync_controls(service)
                    plan=service.image_preview()
                    health.update(pending_count=plan["pending_count"],active_count=plan["active_count"],
                                  error_code=None,error_stage=None)
                except Exception as exc:
                    health.update(enabled=True,workers_running=len(pool),
                                  error_stage="controls_or_preview",error_code=error_code(exc))
                    image_health(root,health)
                    time.sleep(30);continue
                pending=min(plan["pending_count"],max(0,2-plan["active_count"]))
                if plan["maintenance_needed"] and not pending:pending=1
                for slot in range(2):
                    if pending<=0:break
                    if slot in pool:continue
                    logs=root/"image-logs";logs.mkdir(parents=True,exist_ok=True)
                    with (logs/(uuid.uuid4().hex+".log")).open("w",encoding="utf-8") as out:
                        pool[slot]=subprocess.Popen([sys.executable,"-m","v2.ttittulares.news_images_v2",
                            "--root",str(root),"--run-one"],cwd=Path(__file__).resolve().parents[2],
                            stdout=out,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
                    health["last_spawned_at"]=datetime.now(timezone.utc).isoformat()
                    pending-=1
            health.update(enabled=enabled(root),workers_running=len(pool))
            image_health(root,health)
            time.sleep(30)
        health.update(enabled=False,workers_running=0)
        image_health(root,health)

def main():
    parser=argparse.ArgumentParser();parser.add_argument("--root",type=Path,required=True)
    parser.add_argument("--run-one",action="store_true");parser.add_argument("--daemon",action="store_true")
    parser.add_argument("--check",action="store_true")
    args=parser.parse_args();config=settings(args.root);service=NewsService(NewsStore(github_token()))
    if args.check:print(json.dumps(check(service)))
    elif args.daemon:daemon(service,config)
    elif args.run_one:
        sync_controls(service);report=run_one(service,config);print(json.dumps(report))
        if report["status"]=="incident":raise SystemExit(1)
    else:print(json.dumps({"project":"ttittulares-v2","browser_opened":False,"publication_allowed":False}))
if __name__=="__main__":main()
