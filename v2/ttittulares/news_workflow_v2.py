"""News V2 actions and independent image leases. No V1 writes or publication."""
from __future__ import annotations
import base64
import copy
import hashlib
import json
import re
import secrets
import time
from datetime import timedelta
from http.client import IncompleteRead, RemoteDisconnected
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from . import editorial_state_v2 as ed
from .radar_snapshot_v2 import PREFIX, BRANCH, encode, sha256
from .radar_store_v2 import REPOSITORY, Conflict, StoreError, UncertainCommit, _oid

CONTROL_URL = "https://ttactualidad-v2-private-test.fabricelop.workers.dev/api/news-worker-controls"
AUX = re.compile(r"v2/ttittulares/(?:jobs/images/ttn2-[a-f0-9]{24}-r[1-9][0-9]*-image|images/img2-[a-f0-9]{24}|actions/[a-f0-9]{32})\.json\Z")
ID = re.compile(r"ttn2-[a-f0-9]{24}\Z")
ACTION = re.compile(r"[a-f0-9]{32}\Z")

def allowed(path, write=False):
    return ed.allowed(path) or bool(AUX.fullmatch(path))

class NewsStore(ed.EditorialGitHubStore):
    # Only read-only GETs are retried. A POST with an uncertain response must
    # remain fenced by CAS; it is never replayed as if it had not committed.
    def _get(self, suffix):
        transient = {'GITHUB_READ_FAILED', 'GITHUB_HTTP_500', 'GITHUB_HTTP_502',
                     'GITHUB_HTTP_503', 'GITHUB_HTTP_504'}
        for attempt in range(3):
            try:
                return super()._get(suffix)
            except StoreError as exc:
                if str(exc) not in transient or attempt == 2:
                    raise
                time.sleep(.35 * (2 ** attempt))

    def _http_raw(self, commit, path):
        commit = _oid(commit)
        if not allowed(path):
            raise ed.EditorialError("NEWS_PATH_OUTSIDE_SCOPE")
        req = Request("https://raw.githubusercontent.com/"+REPOSITORY+"/"+commit+"/"+path,
                      headers={"User-Agent":"TTNoticiasV2", "Accept":"application/json"})
        for attempt in range(3):
            try:
                # A reset on Windows' public raw CDN is not editorial failure.
                with self._opener.open(req, timeout=20) as response:
                    raw = response.read(16_000_001)
                if len(raw) > 16_000_000:
                    raise ed.EditorialError("NEWS_DOCUMENT_TOO_LARGE")
                return raw
            except HTTPError:
                break  # Pinned file may be delayed on the CDN: use Git's blob.
            except (URLError, TimeoutError, ConnectionError, OSError,
                    IncompleteRead, RemoteDisconnected):
                if attempt < 2:
                    time.sleep(.35 * (2 ** attempt))
        # The authenticated Git blob endpoint is an independent read path.
        # The inventory is already pinned to this commit and _blob_json
        # verifies the SHA1 of the exact bytes returned below.
        entry = self.inventory(commit).get(path)
        if not entry or entry.get('type') != 'blob':
            raise ed.EditorialError('NEWS_PINNED_BLOB_NOT_FOUND')
        try:
            blob = self._get('/git/blobs/' + _oid(entry['sha']))
            if blob.get('encoding') != 'base64' or not isinstance(blob.get('content'), str):
                raise StoreError('NEWS_PINNED_BLOB_ENCODING_INVALID')
            raw = base64.b64decode(''.join(blob['content'].split()), validate=True)
        except (StoreError, ValueError, KeyError, TypeError):
            raise ed.EditorialError('NEWS_PINNED_BLOB_READ_UNAVAILABLE') from None
        if len(raw) > 16_000_000:
            raise ed.EditorialError('NEWS_DOCUMENT_TOO_LARGE')
        return raw

    def read_editorial_snapshot(self):
        head = self.head()
        inventory = self.inventory(head)
        return head, self.read_documents(head, [p for p,e in inventory.items()
            if e.get("type")!="tree" and allowed(p)])

    def commit(self, expected_head, writes, message):
        if not writes or any(not allowed(p, True) for p in writes):
            raise ed.EditorialError("NEWS_COMMIT_OUTSIDE_SCOPE")
        additions=[{"path":p,"contents":base64.b64encode(encode(d).encode()).decode()}
                   for p,d in sorted(writes.items())]
        result=self._request("POST","/graphql",{
            "query":"mutation($input:CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid}}}",
            "variables":{"input":{"branch":{"repositoryNameWithOwner":REPOSITORY,"branchName":BRANCH},
                "expectedHeadOid":expected_head,"message":{"headline":message},
                "fileChanges":{"additions":additions}}}})
        if result.get("errors"):
            if self.head()!=expected_head: raise Conflict("NEWS_HEAD_CHANGED")
            raise ed.EditorialError("NEWS_COMMIT_REJECTED")
        try:return _oid(result["data"]["createCommitOnBranch"]["commit"]["oid"])
        except (KeyError,TypeError):raise UncertainCommit("NEWS_COMMIT_UNCERTAIN") from None

    def save_raster(self, raw, event_id, revision, meta):
        if not ID.fullmatch(event_id) or type(revision) is not int or revision<1:
            raise ed.EditorialError("NEWS_RASTER_ID_INVALID")
        ext={"image/png":"png","image/jpeg":"jpg","image/webp":"webp"}[meta["mime"]]
        path=PREFIX+"images/"+event_id+"-r"+str(revision)+"-"+meta["sha256"][:24]+"."+ext
        blob=self._request("POST","/repos/"+REPOSITORY+"/git/blobs",
            {"content":base64.b64encode(raw).decode(),"encoding":"base64"})
        expected=hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()
        if blob.get("sha")!=expected:raise ed.EditorialError("NEWS_RASTER_BLOB_UNVERIFIED")
        for _ in range(6):
            head=self.head()
            inventory=self.inventory(head)
            if path in inventory:
                if inventory[path]["sha"]!=expected:raise ed.EditorialError("NEWS_RASTER_CONFLICT")
                return path,head
            # Server-side expectedHeadOid through GraphQL prevents overwriting unrelated writes.
            result=self._request("POST","/graphql",{
                "query":"mutation($input:CreateCommitOnBranchInput!){createCommitOnBranch(input:$input){commit{oid}}}",
                "variables":{"input":{"branch":{"repositoryNameWithOwner":REPOSITORY,"branchName":BRANCH},
                    "expectedHeadOid":head,"message":{"headline":"Store original news image "+event_id},
                    "fileChanges":{"additions":[{"path":path,"contents":base64.b64encode(raw).decode()}]}}}})
            if not result.get("errors"):
                saved=_oid(result["data"]["createCommitOnBranch"]["commit"]["oid"])
                if self.inventory(saved).get(path,{}).get("sha")!=expected:
                    raise ed.EditorialError("NEWS_RASTER_READBACK_FAILED")
                return path,saved
        raise Conflict("NEWS_RASTER_CAS_EXHAUSTED")

def image_path(event_id, revision):
    if not ID.fullmatch(event_id) or type(revision) is not int or revision<1:
        raise ed.EditorialError("NEWS_IMAGE_ID_INVALID")
    return PREFIX+"jobs/images/"+event_id+"-r"+str(revision)+"-image.json"

def validate(kind, doc):
    from jsonschema import Draft202012Validator, FormatChecker
    from pathlib import Path
    defs=json.loads((Path(__file__).parent/"schemas/contract.schema.json").read_text(encoding="utf-8"))["$defs"]
    Draft202012Validator({"$ref":"#/$defs/"+kind,"$defs":defs},
                        format_checker=FormatChecker()).validate(doc)

class NewsService(ed.EditorialService):
    @staticmethod
    def _auto_retryable(job, event):
        """A failed/expired *revision* may be fenced and replaced once or twice.

        Old attempts stay immutable for auditing. No prior ChatGPT conversation
        is reopened or resent, and AUTH/disk outages do not spawn chat storms.
        """
        if (job.get("status") != "problematic" or job.get("lease") or
                event.get("current_revision") != job.get("revision") or
                event.get("status") in ed.TERMINAL):
            return False
        code = str((job.get("problem") or {}).get("code", ""))
        if any(x in code for x in ("AUTH", "LOGIN", "CREDENTIAL", "DISK", "CAPTCHA", "SESSION_CLEANUP")):
            return False
        # Limit retries across revisions, not just attempts of one job.
        return sum(r.get("reason") == "automatic_retry" for r in event.get("revision_refs", [])) < 2

    def _preview_more(self, docs, news, jobs, plan):
        eligible = any(self._in_scope(j) and self._auto_retryable(j, news[j["event_id"]])
                       and not ed._blocked(news[j["event_id"]], j, docs)
                       and ed.record_path(j) not in docs for j in jobs.values())
        return {"automatic_retry_pending": eligible,
                "maintenance_needed": plan["maintenance_needed"] or
                                      (eligible and plan["pending_count"] == 0)}

    def retry_problematic(self):
        """Durably schedule a new exact revision after a quarantined failure.

        CAS fencing of the old revision prevents a late result from becoming
        READY; a new consumer claim creates a fresh browser/chat and command ID.
        """
        for _ in range(self.max_attempts):
            head, docs = self.store.read_editorial_snapshot()
            news, jobs = ed._snapshot(docs)
            candidates = [j for j in jobs.values()
                          if self._in_scope(j) and self._auto_retryable(j, news[j["event_id"]])
                          and not ed._blocked(news[j["event_id"]], j, docs)
                          and ed.record_path(j) not in docs]
            candidates.sort(key=lambda j: (j["requested_at"], j["job_id"]))
            if not candidates:
                return False
            old = candidates[0]
            event = news[old["event_id"]]
            # Never requeue an event with a verified record, including cases
            # where completing its last status commit was interrupted.
            stamp = ed._stamp(self.clock())
            revision = old["revision"] + 1
            jid = f"{event['event_id']}-r{revision}-editorial"
            if ed.job_path(jid) in docs:
                raise ed.EditorialError("AUTO_RETRY_JOB_ALREADY_EXISTS")
            new = copy.deepcopy(old)
            new.update(job_id=jid, revision=revision, status="pending", phase="queued",
                       priority="automatic", requested_at=stamp, updated_at=stamp,
                       prompt=None, lease=None, send_intent=None, session=None,
                       capture=None, result=None, problem=None,
                       attempts={"claim_count":0,"submission_count":0,"safe_preflight_failures":0,
                                 "max_safe_preflight_attempts":3,"history":[]})
            event.update(current_revision=revision, status="editorial_pending",
                         current_record_path=None, updated_at=stamp)
            for ref in event["revision_refs"]:
                if ref["revision"] == old["revision"]:
                    ref["status"] = "problematic"
            event["revision_refs"].append({"revision":revision,"reason":"automatic_retry",
                "status":"pending","requested_at":stamp,"editorial_job_id":jid})
            jobs[jid] = new
            index_item = docs[ed.INDEX]["items"][event["event_id"]]
            for key in ("image", "image_incident", "image_progress", "editorial_sha256"):
                index_item.pop(key, None)
            writes = {ed.job_path(jid):new,
                      PREFIX+"news/"+event["event_id"]+".json":event}
            ed._projections(docs, news, jobs, writes)
            validate("editorial_job", new)
            validate("news_event", event)
            validate("queue_index", writes[ed.QUEUE])
            try:
                commit = self.store.commit(head, writes, "News V2: fresh editorial chat after incident")
            except (Conflict, UncertainCommit):
                continue
            verified = self.store.read_documents(commit, list(writes))
            if verified != writes:
                raise ed.EditorialError("AUTO_RETRY_READBACK_MISMATCH")
            return True
        raise Conflict("NEWS_AUTO_RETRY_CAS_EXHAUSTED")

    def controls(self, controls):
        if not isinstance(controls,dict) or not isinstance(controls.get("actions"),list):
            raise ed.EditorialError("NEWS_CONTROLS_INVALID")
        self.image_preferences=controls.get("preferences", [])
        self.image_retry_requests=[a for a in controls["actions"] if isinstance(a,dict) and a.get("action")=="retry_image"]
        pending=[a for a in controls["actions"] if a.get("action") in ("archive","rework","rework_x","retry_editorial","dismiss","urgent")]
        if not pending:return
        _,docs=self.store.read_editorial_snapshot()
        news,_=ed._snapshot(docs)
        for action in pending:
            if PREFIX+"actions/"+str(action.get("action_id"))+".json" in docs:continue
            event=news.get(action.get("event_id"))
            if not event or event["current_revision"]!=action.get("revision"):continue
            self.apply_action(action)

    def apply_action(self, action):
        if not ACTION.fullmatch(str(action.get("action_id",""))) or not ID.fullmatch(str(action.get("event_id",""))):
            raise ed.EditorialError("NEWS_ACTION_INVALID")
        if action.get("action") not in ("archive","rework","rework_x","retry_editorial","dismiss","urgent"):
            raise ed.EditorialError("NEWS_ACTION_INVALID")
        path=PREFIX+"actions/"+action["action_id"]+".json"
        for _ in range(self.max_attempts):
            head,docs=self.store.read_editorial_snapshot()
            if path in docs:return {"verified":True,"replay":True}
            news,jobs=ed._snapshot(docs);event=news.get(action["event_id"])
            if not event or event["current_revision"]!=action.get("revision"):
                return {"verified":False,"stale":True}
            previous=jobs.get(event["event_id"]+"-r"+str(event["current_revision"])+"-editorial")
            pending_action=(action["action"]=="urgent" or
                            action["action"]=="dismiss" and previous and previous["status"]=="pending")
            if pending_action:
                if (event["status"] in ed.TERMINAL or not previous or
                        previous["status"]!="pending" or previous.get("lease") or
                        ed.record_path(previous) in docs or
                        (action["action"]=="urgent" and previous["priority"]=="urgent")):
                    return {"verified":False,"stale":True}
            elif action["action"] in ("retry_editorial","dismiss"):
                if (event["status"] in ed.TERMINAL or not previous or
                        previous["status"]!="problematic" or previous.get("lease") or
                        ed.record_path(previous) in docs):
                    return {"verified":False,"stale":True}
                code=str((previous.get("problem") or {}).get("code", ""))
                if (action["action"]=="retry_editorial" and
                        any(x in code for x in ("AUTH","LOGIN","CREDENTIAL","DISK","CLEANUP","CAPTCHA","LEASE_EXPIRED"))):
                    return {"verified":False,"unsafe":True}
            elif event["status"]!="ready":
                return {"verified":False,"stale":True}
            now=ed._stamp(self.clock());writes={}
            decision={"schema_version":1,"project":"ttittulares-v2",
                "decision_id":"dcn2-"+action["action_id"][:24],"event_id":event["event_id"],
                "revision":event["current_revision"],
                "action":"prioritize" if action["action"]=="urgent" else "dismiss" if action["action"]=="dismiss" else "archive" if action["action"]=="archive" else "request_rework",
                "actor":"private-web","occurred_at":now,"idempotency_key":action["action_id"]}
            if action["action"]=="urgent":
                previous["priority"]="urgent"
                previous["updated_at"]=now
                writes[ed.job_path(previous["job_id"])]=copy.deepcopy(previous)
            if action["action"] in ("archive","dismiss"):
                event.update(status="dismissed" if action["action"]=="dismiss" else "archived",updated_at=now)
                if action["action"]=="dismiss":
                    for ref in event["revision_refs"]:
                        if ref["revision"]==event["current_revision"]:ref["status"]="dismissed"
                    if pending_action:
                        previous.update(status="cancelled",phase="done",lease=None,updated_at=now)
                        writes[ed.job_path(previous["job_id"])]=copy.deepcopy(previous)
            elif action["action"]!="urgent":
                hints=str(action.get("hints") or "").strip()
                if action["action"]=="rework_x" and not 10<=len(hints)<=1200:
                    raise ed.EditorialError("NEWS_REWORK_HINTS_INVALID")
                if action["action"]=="retry_editorial":
                    code=str((previous.get("problem") or {}).get("code",""))
                    instructions={
                        "INVALID_EDITORIAL_JSON":"Respeta el contrato exacto TTN2_EDITORIAL_READY o TTN2_EDITORIAL_BLOCKED, sin Markdown ni contenido extra.",
                        "INVALID_UTC_TIMESTAMP":"Usa fechas UTC ISO 8601 estrictas, verificando cada marca antes de responder.",
                        "ESSENTIAL_FACT_NOT_VERIFIED":"Busca fuentes verdaderamente independientes; si el hecho esencial no se acredita, responde BLOCKED.",
                    }
                    hints="Reintento manual tras incidencia "+code+". Abre un chat editorial nuevo, investiga desde cero, no reutilices respuestas previas. "+instructions.get(code,"Contrasta los hechos de nuevo con al menos dos fuentes independientes.")
                decision["rework"]={"scope":"reinvestigate","instructions":
                    ("Investiga también X y contrasta estas pistas: "+hints) if action["action"]=="rework_x" else
                    hints if action["action"]=="retry_editorial" else
                    "Investiga de nuevo el hecho y redacta una explicación nueva."}
                rev=event["current_revision"]+1;jid=event["event_id"]+"-r"+str(rev)+"-editorial"
                old=jobs[event["event_id"]+"-r"+str(rev-1)+"-editorial"]
                job=copy.deepcopy(old)
                job.update(job_id=jid,revision=rev,status="pending",phase="queued",priority="manual_rework",
                    requested_at=now,updated_at=now,prompt=None,lease=None,send_intent=None,session=None,capture=None,result=None,problem=None,
                    attempts={"claim_count":0,"submission_count":0,"safe_preflight_failures":0,
                              "max_safe_preflight_attempts":3,"history":[]})
                jobs[jid]=job;writes[ed.job_path(jid)]=job
                event.update(current_revision=rev,status="editorial_pending",current_record_path=None,updated_at=now)
                event["revision_refs"].append({"revision":rev,"reason":"user_rework","status":"pending",
                    "requested_at":now,"editorial_job_id":jid})
                for key in ("image","image_incident","image_progress","editorial_sha256"):
                    docs[ed.INDEX]["items"][event["event_id"]].pop(key,None)
            validate("decision_event",decision)
            writes[PREFIX+"decisions/"+event["event_id"]+"/"+decision["decision_id"]+".json"]=decision
            writes[PREFIX+"news/"+event["event_id"]+".json"]=event
            writes[path]=copy.deepcopy(action)
            ed._projections(docs,news,jobs,writes)
            try:
                commit=self.store.commit(head,writes,"News action "+action["action"])
                if self.store.read_documents(commit,[path])[path]!=action:
                    raise ed.EditorialError("NEWS_ACTION_READBACK_FAILED")
                return {"verified":True,"commit_sha":commit}
            except (Conflict,UncertainCommit):continue
        raise Conflict("NEWS_ACTION_RETRY_EXHAUSTED")

    def claim(self, worker_id, token):
        result=super().claim(worker_id,token)
        if not result.get("job") and self.retry_problematic():
            result=super().claim(worker_id,token)
        if result.get("job"):
            _,docs=self.store.read_editorial_snapshot()
            job=result["job"];prior=job["revision"]-1
            hints=[d.get("rework",{}).get("instructions","") for p,d in docs.items()
                   if ed.DECISION.fullmatch(p) and d.get("event_id")==job["event_id"]
                   and d.get("revision")==prior and d.get("action")=="request_rework"]
            if prior > 0 and any(ref.get("revision")==job["revision"] and
                                  ref.get("reason")=="automatic_retry"
                                  for ref in docs.get(PREFIX+"news/"+job["event_id"]+".json",{}).get("revision_refs",[])):
                previous=docs.get(ed.job_path(job["event_id"]+"-r"+str(prior)+"-editorial"),{})
                reason=(previous.get("problem") or {}).get("code","")
                corrective={
                    "INVALID_EDITORIAL_JSON":"Respeta exactamente el contrato estructurado TTN2_EDITORIAL_READY o TTN2_EDITORIAL_BLOCKED. Sin texto adicional ni bloques Markdown.",
                    "INVALID_UTC_TIMESTAMP":"Escribe las fechas UTC en formato ISO 8601 estricto con zona Z; comprueba cada timestamp antes de responder.",
                    "ESSENTIAL_FACT_NOT_VERIFIED":"Contrasta de nuevo el hecho esencial con dos fuentes realmente independientes; si no se acredita, responde BLOCKED con el motivo concreto.",
                }
                hints.append("Nuevo chat independiente después de incidencia anterior "+reason+". " +
                             corrective.get(reason,"Investiga de nuevo el acontecimiento completo; no reutilices respuestas previas."))
            result["hints"]="\n".join(hints)[-4000:]
        return result

    def image_preview(self):
        """Read-only dispatch plan; idle daemons do not launch browser workers."""
        head,docs=self.store.read_editorial_snapshot()
        news,_=ed._snapshot(docs);now=self.clock()
        rows=[j for p,j in docs.items() if p.startswith(PREFIX+"jobs/images/")]
        active=[j for j in rows if j.get("lease")]
        pending=0
        for event in news.values():
            if event["status"]!="ready":continue
            indexed=docs[ed.INDEX]["items"].get(event["event_id"],{})
            image=indexed.get("image") or {}
            if image.get("revision")==event["current_revision"] and image.get("verified") is True:
                continue
            previous=docs.get(image_path(event["event_id"],event["current_revision"]))
            if previous and not (self._fresh_image_retry_eligible(previous) or self._manual_image_retry_action(event,previous)):continue
            pref=next((x for x in getattr(self,"image_preferences",[]) if x.get("event_id")==event["event_id"] and x.get("revision")==event["current_revision"]),{})
            if not (pref.get("manual_image") or pref.get("image_suppressed") or pref.get("rework_requested") or pref.get("archived")):pending+=1
        return {"commit_sha":head,"pending_count":pending,"active_count":len(active),
                "maintenance_needed":any(ed._time(j["lease"]["expires_at"])<=now for j in active),
                "publication_allowed":False}

    @staticmethod
    def _fresh_image_retry_eligible(job):
        """Retry only a *closed* failed image attempt in a new owned chat.

        The discarded image is never associated with the news. Editorial jobs
        retain their stricter no-resend policy, and uncertain active Chrome
        cleanup must be investigated rather than launching another process.
        """
        attempts=job.get("attempts") or {}
        problem=job.get("problem") or {}
        code=str(problem.get("code") or "")
        # Pre-migration image failures often said "recover_same_chat", which
        # left otherwise READY news without images forever. The editor has
        # explicitly chosen a NEW disposable chat after each such failure.
        # Never override an auth, disk, cleanup or active-lease safety stop.
        retry_mode=problem.get("retry_mode")
        fresh=retry_mode in ("new_chat", "recover_same_chat") or NewsService._legacy_preflight_image_repair(job)
        safe=not any(part in code for part in ("AUTH", "LOGIN", "CREDENTIAL", "DISK", "CLEANUP", "CAPTCHA"))
        remaining=attempts.get("claim_count",0)<attempts.get("max_safe_preflight_attempts",3)
        return (job.get("status")=="problematic" and not job.get("lease")
                and fresh and safe and (remaining or NewsService._legacy_preflight_image_repair(job)))

    @staticmethod
    def _legacy_preflight_image_repair(job):
        """One extra fresh chat for today's pre-send failures under the old CAS bug.

        All three prior attempts must have demonstrably sent *nothing*. This
        narrowly-scoped migration never retries an uncertain actual ImageGen
        submission, historic jobs, or a job failing again after this repair.
        """
        attempts=job.get("attempts") or {};problem=job.get("problem") or {}
        history=attempts.get("history") or []
        return (job.get("status")=="problematic" and job.get("lease") is None
                and job.get("send_intent") is None
                and problem.get("code")=="NEWS_IMAGE_UNCERTAIN_NO_RESEND"
                and problem.get("retry_mode")=="manual_only"
                and attempts.get("claim_count")==3
                and attempts.get("max_safe_preflight_attempts")==3
                and attempts.get("submission_count")==0
                and attempts.get("safe_preflight_failures")==3
                and len(history)==3
                and all(item.get("outcome")=="preflight_failed" for item in history)
                and str(job.get("requested_at") or "")>="2026-11-17T23:00:00Z")

    def _manual_image_retry_action(self, event, job):
        """An explicit private-web action authorizes ONE fresh attempt at this exact incident.

        The manual request is independent of the automatic three-attempt ceiling,
        but it never overrides an active lease, unsafe cleanup or a newer incident.
        """
        if not job or job.get("status")!="problematic" or job.get("lease"):
            return None
        problem=job.get("problem") or {}
        code=str(problem.get("code") or "")
        if (problem.get("retry_mode")=="none" or
                any(part in code for part in ("AUTH","LOGIN","CREDENTIAL","DISK","CLEANUP","CAPTCHA","LEASE_EXPIRED"))):
            return None
        for action in reversed(getattr(self,"image_retry_requests",[])):
            if (action.get("event_id")==event["event_id"] and
                    action.get("revision")==event["current_revision"] and
                    action.get("incident_at")==problem.get("at") and
                    ACTION.fullmatch(str(action.get("action_id",""))) and
                    (job.get("policy") or {}).get("reason")!="retry_image:"+action["action_id"]):
                return action
        return None

    def image(self, operation, *, worker_id, token, job_id=None, **data):
        if not ed.SAFE_ID.fullmatch(worker_id):raise ed.EditorialError("NEWS_IMAGE_WORKER_INVALID")
        token_hash=ed._secret(token)
        for _ in range(self.max_attempts):
            now=self.clock();stamp=ed._stamp(now)
            head,docs=self.store.read_editorial_snapshot();news,jobs=ed._snapshot(docs);writes={}
            imagejobs={p:d for p,d in docs.items() if p.startswith(PREFIX+"jobs/images/")}
            if operation=="claim":
                for p,j in imagejobs.items():
                    if j["status"] in ("claimed","send_intent","generating","captured","persisting") and ed._time(j["lease"]["expires_at"])<=now:
                        j.update(status="problematic",phase="blocked",lease=None,
                            problem={"code":"NEWS_IMAGE_LEASE_EXPIRED","at":stamp,"retry_mode":"recover_same_chat" if j["send_intent"] else "manual_only"})
                        writes[p]=j
                        index=writes.setdefault(ed.INDEX,copy.deepcopy(docs[ed.INDEX]))
                        item=index["items"].get(j["event_id"],{})
                        if item.get("current_revision")==j["revision"]:
                            item["editorial_sha256"]=j["editorial_sha256"]
                            item["image_incident"]={**j["problem"],"revision":j["revision"],"editorial_sha256":j["editorial_sha256"]}
                            item.pop("image_progress",None)
                active=[j for j in imagejobs.values() if j["lease"]]
                owned=next((j for j in active if j["lease"]["worker_id"]==worker_id and j["lease"]["token_sha256"]==token_hash),None)
                if owned:return {"job":copy.deepcopy(owned),"record":docs[owned["source_record_path"]],"replay":True}
                candidates=sorted([e for e in news.values() if e["status"]=="ready"],
                    key=lambda e:(0 if self._manual_image_retry_action(e,imagejobs.get(image_path(e["event_id"],e["current_revision"]))) else 1,
                                  e["created_at"],e["event_id"]))
                selected=None
                if len(active)<2:
                    for event in candidates:
                        indexed=docs[ed.INDEX]["items"].get(event["event_id"],{})
                        image=indexed.get("image") or {}
                        if image.get("revision")==event["current_revision"] and image.get("verified") is True:
                            continue
                        p=image_path(event["event_id"],event["current_revision"])
                        prior=imagejobs.get(p)
                        manual=self._manual_image_retry_action(event,prior)
                        if prior and not (manual or self._fresh_image_retry_eligible(prior)):continue
                        pref=next((x for x in getattr(self,"image_preferences",[]) if x.get("event_id")==event["event_id"] and x.get("revision")==event["current_revision"]),{})
                        if pref.get("manual_image") or pref.get("image_suppressed") or pref.get("rework_requested") or pref.get("archived"):continue
                        record=docs.get(event.get("current_record_path"))
                        if not record or record["record_status"]!="ready":continue
                        digest=record["editorial_sha256"]
                        selected={"schema_version":1,"project":"ttittulares-v2","job_id":event["event_id"]+"-r"+str(event["current_revision"])+"-image",
                            "event_id":event["event_id"],"revision":event["current_revision"],"status":"claimed","phase":"claiming",
                            "source_record_path":event["current_record_path"],"editorial_sha256":digest,
                            "prompt_version":"news-image-v2","prompt_sha256":"0"*64,
                            "policy":{"mode":"automatic","visual_treatment":"editorial_gag"},
                            "attempts":{"claim_count":1,"submission_count":0,"safe_preflight_failures":0,"max_safe_preflight_attempts":3,"history":[]},
                            "lease":{"worker_id":worker_id,"token_sha256":token_hash,"claimed_at":stamp,
                                     "heartbeat_at":stamp,"expires_at":ed._stamp(now+timedelta(minutes=25))},
                            "send_intent":None,"session":None,"capture":None,"result":None,"problem":None,
                            "requested_at":stamp,"updated_at":stamp}
                        # Schema uses acquired_at rather than claimed_at in leases.
                        selected["lease"]=self._image_lease(worker_id,token_hash,now)
                        if prior:
                            # Preserve previous command IDs, outcomes and attempt
                            # counts. A fresh run gets its own browser and UUID.
                            selected["attempts"]=copy.deepcopy(prior["attempts"])
                            selected["attempts"]["claim_count"]+=1
                            if self._legacy_preflight_image_repair(prior):
                                selected["attempts"]["max_safe_preflight_attempts"]=4
                            selected["requested_at"]=prior["requested_at"]
                        if manual:
                            selected["policy"]={"mode":"manual_request","visual_treatment":"editorial_gag",
                                "reason":"retry_image:"+manual["action_id"]}
                        writes[p]=selected;imagejobs[p]=selected;break
                if selected is None:
                    if writes:
                        try:self.store.commit(head,writes,"Quarantine expired news image jobs")
                        except (Conflict,UncertainCommit):continue
                    return {"job":None}
                job=selected
            else:
                p=next((p for p,j in imagejobs.items() if j["job_id"]==job_id),None)
                if not p:raise ed.EditorialError("NEWS_IMAGE_JOB_MISSING")
                job=imagejobs[p];event=news[job["event_id"]]
                if operation=="save" and job["status"]=="saved":
                    if job["result"]["sha256"]!=data["asset"]["sha256"]:raise ed.EditorialError("NEWS_IMAGE_IMMUTABLE_MISMATCH")
                    return {"job":job,"verified":True,"replay":True,"commit_sha":head}
                lease=job.get("lease") or {}
                if lease.get("worker_id")!=worker_id or lease.get("token_sha256")!=token_hash or ed._time(lease["expires_at"])<=now:
                    raise ed.EditorialError("NEWS_IMAGE_LEASE_NOT_OWNED")
                # A job started in ELAB may finish after the user moves that
                # unchanged revision to Archivo. Never attach after a rework,
                # deletion or any change to the immutable editorial identity.
                if event["status"] not in ("ready","archived") or event["current_revision"]!=job["revision"] or docs[job["source_record_path"]]["editorial_sha256"]!=job["editorial_sha256"]:
                    raise ed.EditorialError("NEWS_IMAGE_SOURCE_CHANGED")
                if operation=="heartbeat":
                    job["lease"]["expires_at"]=ed._stamp(now+timedelta(minutes=25));job["lease"]["heartbeat_at"]=stamp
                elif operation=="prepare":
                    if job["status"]!="claimed" or job["send_intent"]:
                        return {"send_authorized":False,"reason":"NEWS_IMAGE_INTENT_ALREADY_EXISTS"}
                    job.update(status="send_intent",phase="sending",prompt_sha256=data["prompt_sha256"],session=data["session"],
                        send_intent={"command_id":data["command_id"],"attempt_no":job["attempts"]["claim_count"],"prompt_sha256":data["prompt_sha256"],
                                     "prepared_at":stamp,"submission_state":"prepared","submitted_at":None})
                elif operation=="submitted":
                    job.update(status="generating",phase="generating")
                    job["send_intent"].update(submission_state="confirmed",submitted_at=stamp)
                    job["attempts"]["submission_count"]+=1
                elif operation=="save":
                    if data.get("cleanup_verified") is not True:raise ed.EditorialError("NEWS_IMAGE_CLEANUP_REQUIRED")
                    asset=copy.deepcopy(data["asset"]);validate("image_asset",asset)
                    if asset["event_id"]!=job["event_id"] or asset["revision"]!=job["revision"] or asset["editorial_sha256"]!=job["editorial_sha256"] or asset["command_id"]!=job["send_intent"]["command_id"]:
                        raise ed.EditorialError("NEWS_IMAGE_ASSET_IDENTITY_INVALID")
                    writes[PREFIX+"images/"+asset["media_id"]+".json"]=asset
                    job.update(status="saved",phase="done",lease=None,capture={"raster_sha256":asset["sha256"],
                        "captured_at":stamp,"mime":asset["mime"],"width":asset["width"],"height":asset["height"],"bytes":asset["bytes"]},
                        result={"asset_path":asset["asset_path"],"media_id":asset["media_id"],"sha256":asset["sha256"],"commit_sha":data["raster_commit"]})
                    job["attempts"]["history"].append({"attempt_no":job["attempts"]["claim_count"],
                        "command_id":job["send_intent"]["command_id"],"at":stamp,"outcome":"captured"})
                elif operation=="fail":
                    code=data["code"]
                    if not re.fullmatch(r"[A-Z][A-Z0-9_]{2,100}",code):raise ed.EditorialError("NEWS_IMAGE_UNSAFE_ERROR")
                    sent=job.get("send_intent")
                    if not sent:job["attempts"]["safe_preflight_failures"]+=1
                    job["attempts"]["history"].append({"attempt_no":job["attempts"]["claim_count"],
                        "command_id":sent["command_id"] if sent else "no-send-"+str(job["attempts"]["claim_count"]),
                        "at":stamp,"outcome":("failed_after_submit" if sent and sent["submission_state"]=="confirmed"
                                             else "uncertain" if sent else "preflight_failed")})
                    # A new image may be generated even if the old send was
                    # uncertain; never reuse its chat, command ID or raster.
                    safe_closed=(data.get("cleanup_verified") is True and "AUTH" not in code
                                 and code not in ("NEWS_DISK_SPACE_LOW_NO_NEW_CHROME",))
                    retry_mode=("none" if not data.get("cleanup_verified") else
                                "new_chat" if safe_closed and job["attempts"]["claim_count"]<job["attempts"]["max_safe_preflight_attempts"] else "manual_only")
                    job.update(status="problematic",phase="blocked",lease=None,
                        problem={"code":code,"at":stamp,"retry_mode":retry_mode})
                else:raise ed.EditorialError("NEWS_IMAGE_OPERATION_INVALID")
                job["updated_at"]=stamp;writes[p]=job
            validate("image_job",job)
            index=copy.deepcopy(writes.get(ed.INDEX,docs[ed.INDEX]));item=index["items"][job["event_id"]]
            item["editorial_sha256"]=job["editorial_sha256"]
            if job["status"]=="saved":
                item["image"]=copy.deepcopy(data["asset"]);item.pop("image_incident",None);item.pop("image_progress",None)
            elif job["status"]=="problematic":
                item["image_incident"]={**job["problem"],"event_id":job["event_id"],"revision":job["revision"],"editorial_sha256":job["editorial_sha256"]}
                item.pop("image_progress",None)
            else:
                item.pop("image_incident",None)
                item["image_progress"]={"revision":job["revision"],"editorial_sha256":job["editorial_sha256"],"expires_at":job["lease"]["expires_at"]}
            writes[ed.INDEX]=index
            try:
                commit=self.store.commit(head,writes,"News image "+operation)
                if self.store.read_documents(commit,[p])[p]!=job:raise ed.EditorialError("NEWS_IMAGE_READBACK_FAILED")
                return {"job":copy.deepcopy(job),"record":docs[job["source_record_path"]],"verified":True,
                        "commit_sha":commit,"send_authorized":operation=="prepare"}
            except Conflict:
                # GitHub rejected this optimistic write: nothing was committed
                # and no image prompt has been sent. Refresh the snapshot and
                # retry safely, even for prepare, just as the trend worker
                # tolerates unrelated concurrent state changes.
                continue
            except UncertainCommit:
                if operation=="prepare":
                    # A lost POST response is different from a rejected CAS.
                    # Never write a second intent, but a *read-only* fresh
                    # snapshot can prove that this exact first intent landed.
                    # Browser.send_once has not been reached at this point.
                    try:
                        confirmed_head,confirmed_docs=self.store.read_editorial_snapshot()
                        confirmed=confirmed_docs.get(p) or {}
                        intent=confirmed.get("send_intent") or {}
                        owner=confirmed.get("lease") or {}
                        event_now=confirmed_docs.get(PREFIX+"news/"+job["event_id"]+".json") or {}
                        record_now=confirmed_docs.get(job["source_record_path"]) or {}
                        if (confirmed.get("status")=="send_intent"
                            and confirmed.get("job_id")==job_id
                            and confirmed.get("attempts",{}).get("submission_count")==job["attempts"]["submission_count"]
                            and confirmed.get("session")==data["session"]
                            and confirmed.get("prompt_sha256")==data["prompt_sha256"]
                            and intent.get("command_id")==data["command_id"]
                            and intent.get("attempt_no")==job["attempts"]["claim_count"]
                            and intent.get("prompt_sha256")==data["prompt_sha256"]
                            and intent.get("submission_state")=="prepared"
                            and intent.get("submitted_at") is None
                            and owner.get("worker_id")==worker_id
                            and owner.get("token_sha256")==token_hash
                            and ed._time(owner["expires_at"])>self.clock()
                            and event_now.get("status") in ("ready","archived")
                            and event_now.get("current_revision")==job["revision"]
                            and record_now.get("editorial_sha256")==job["editorial_sha256"]):
                            return {"job":copy.deepcopy(confirmed),"record":record_now,
                                "verified":True,"commit_sha":confirmed_head,
                                "send_authorized":True,"reconciled":True}
                    except Exception:
                        # Incomplete or unavailable readback must never be
                        # converted into permission to submit an image.
                        pass
                    return {"send_authorized":False,"reason":"NEWS_IMAGE_PREPARE_UNVERIFIED"}
                continue
        raise Conflict("NEWS_IMAGE_RETRY_EXHAUSTED")

    def _image_lease(self,worker_id,token_hash,now):
        return {"worker_id":worker_id,"token_sha256":token_hash,
                "started_at":ed._stamp(now),"heartbeat_at":ed._stamp(now),
                "expires_at":ed._stamp(now+timedelta(minutes=25))}

def read_controls(token):
    with urlopen(Request(CONTROL_URL,headers={"Accept":"application/json","User-Agent":"TTNoticiasV2",
        "Authorization":"Bearer "+token}),timeout=30) as response:
        return json.load(response)

def sync_controls(service):
    controls=read_controls(service.store._token);service.controls(controls)
    return controls
