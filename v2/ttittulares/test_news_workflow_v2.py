"""Actions, immutable image association and lease regressions; no live browser."""
import copy, unittest
from datetime import timedelta
from . import test_editorial_state_v2 as fixtures
from .news_workflow_v2 import NewsService,image_path
from . import editorial_state_v2 as ed
from .test_radar_ingest_v2 import BASE

class NewsEditorialAutoRetryTests(unittest.TestCase):
 def setUp(self):
  self.now=BASE+timedelta(minutes=1)
  self.store=fixtures.MemoryEditorialStore(fixtures.documents(count=1))
  self.service=NewsService(self.store,clock=lambda:self.now,lease_seconds=120)
  self.token="retry-test-private-token-123456789012345"
 def fail_first(self,code="NEWS_CAPTURE_TIMEOUT"):
  claim=self.service.claim("worker-first",self.token);job=claim["job"]
  self.service.prepare_send(job["job_id"],"worker-first",self.token,"b"*64,"command-original",
   {"session_id":"session-original","private_journal_id":"journal-original","conversation_url_sha256":"c"*64})
  self.service.submitted(job["job_id"],"worker-first",self.token)
  self.service.fail(job["job_id"],"worker-first",self.token,code)
  return job
 def test_failed_elaboration_creates_new_revision_and_new_chat_slot(self):
  old=self.fail_first()
  plan=self.service.preview();self.assertTrue(plan["automatic_retry_pending"])
  next_job=self.service.claim("worker-second","retry-second-token-123456789012345")["job"]
  self.assertEqual(next_job["revision"],2)
  self.assertIsNone(next_job["session"]);self.assertIsNone(next_job["send_intent"])
  self.assertEqual(next_job["attempts"]["submission_count"],0)
  _,docs=self.store.read_editorial_snapshot()
  self.assertEqual(docs[ed.job_path(old["job_id"])]["status"],"problematic")
  event=docs[ed.PREFIX+"news/"+old["event_id"]+".json"]
  self.assertEqual(event["current_revision"],2)
  self.assertEqual(event["revision_refs"][-1]["reason"],"automatic_retry")
  with self.assertRaises(ed.EditorialError):
   self.service.heartbeat(old["job_id"],"worker-first",self.token)
 def test_fresh_editorial_retry_gets_reason_specific_instructions(self):
  self.fail_first("INVALID_UTC_TIMESTAMP")
  claim=self.service.claim("worker-second","retry-second-token-123456789012345")
  self.assertEqual(claim["job"]["revision"],2)
  self.assertIn("ISO 8601",claim["hints"])
  self.assertIn("Nuevo chat independiente",claim["hints"])
 def test_auth_failure_is_not_repeated_indefinitely(self):
  self.fail_first("NEWS_AUTH_REQUIRED")
  self.assertFalse(self.service.preview().get("automatic_retry_pending",False))
  self.assertIsNone(self.service.claim("worker-second","retry-second-token-123456789012345")["job"])
 def test_only_two_fresh_retries_are_scheduled(self):
  self.fail_first()
  for revision in (2,3):
   self.assertTrue(self.service.retry_problematic())
   job=self.service.claim("worker-"+str(revision),"retry-token-%s-123456789012345678"%revision)["job"]
   self.service.fail(job["job_id"],"worker-"+str(revision),"retry-token-%s-123456789012345678"%revision,"NEWS_CAPTURE_TIMEOUT")
  self.assertFalse(self.service.retry_problematic())
 def test_incident_manual_retry_creates_new_revision_and_problem_specific_fresh_chat_hint(self):
  old=self.fail_first("INVALID_EDITORIAL_JSON")
  action={"action_id":"b"*32,"event_id":old["event_id"],"revision":1,"action":"retry_editorial"}
  self.assertTrue(self.service.apply_action(action)["verified"])
  self.assertTrue(self.service.apply_action(action)["replay"])
  _,docs=self.store.read_editorial_snapshot()
  event=docs[ed.PREFIX+"news/"+old["event_id"]+".json"]
  self.assertEqual(event["current_revision"],2)
  self.assertEqual(event["revision_refs"][-1]["reason"],"user_rework")
  self.assertEqual(docs[ed.job_path(old["job_id"])]["status"],"problematic")
  new=docs[ed.job_path(old["event_id"]+"-r2-editorial")]
  self.assertEqual(new["status"],"pending")
  self.assertIsNone(new["session"])
  self.assertIsNone(new["send_intent"])
  self.assertEqual(new["attempts"]["claim_count"],0)
  claimed=self.service.claim("manual-fresh-worker","fresh-private-token-123456789012345")
  self.assertEqual(claimed["job"]["revision"],2)
  self.assertIn("chat editorial nuevo",claimed["hints"])
  self.assertIn("TTN2_EDITORIAL_READY",claimed["hints"])
  self.assertNotIn("Investiga también X",claimed["hints"])
 def test_incident_suppression_is_terminal_without_erasing_the_failed_job(self):
  old=self.fail_first("ESSENTIAL_FACT_NOT_VERIFIED")
  action={"action_id":"c"*32,"event_id":old["event_id"],"revision":1,"action":"dismiss"}
  self.service.controls({"actions":[action],"preferences":[]})
  _,docs=self.store.read_editorial_snapshot()
  event=docs[ed.PREFIX+"news/"+old["event_id"]+".json"]
  self.assertEqual(event["status"],"dismissed")
  self.assertEqual(event["revision_refs"][-1]["status"],"dismissed")
  self.assertEqual(docs[ed.job_path(old["job_id"])]["status"],"problematic")
  self.assertEqual(docs[ed.INDEX]["items"][old["event_id"]]["terminal_status"],"dismissed")
  self.assertNotIn(old["event_id"],[row["event_id"] for row in docs[ed.QUEUE]["items"]])
  self.assertFalse(self.service.preview().get("automatic_retry_pending"))
  self.assertTrue(self.service.apply_action(action)["replay"])
 def test_incident_retry_refuses_unsafe_environment_and_stale_revision(self):
  old=self.fail_first("NEWS_OWN_CHROME_CLEANUP_UNVERIFIED")
  action={"action_id":"d"*32,"event_id":old["event_id"],"revision":1,"action":"retry_editorial"}
  self.assertTrue(self.service.apply_action(action)["unsafe"])
  self.assertTrue(self.service.apply_action({**action,"action":"dismiss"})["verified"])
  self.assertTrue(self.service.apply_action({**action,"action_id":"e"*32})["stale"])
 def test_pending_suppression_removes_job_from_queue_and_preserves_audit(self):
  _,docs=self.store.read_editorial_snapshot()
  event=next(iter(x for x in docs.values() if isinstance(x,dict) and x.get("status")=="editorial_pending"))
  action={"action_id":"f"*32,"event_id":event["event_id"],"revision":1,"action":"dismiss"}
  self.assertTrue(self.service.apply_action(action)["verified"])
  _,after=self.store.read_editorial_snapshot()
  self.assertEqual(after[ed.PREFIX+"news/"+event["event_id"]+".json"]["status"],"dismissed")
  self.assertEqual(after[ed.INDEX]["items"][event["event_id"]]["terminal_status"],"dismissed")
  self.assertNotIn(event["event_id"],[j["event_id"] for j in after[ed.QUEUE]["items"]])
  self.assertEqual(after[ed.job_path(event["event_id"]+"-r1-editorial")]["status"],"cancelled")
  self.assertIsNone(self.service.claim("next-worker","another-worker-token-123456789012345")["job"])
  self.assertTrue(self.service.apply_action(action)["replay"])
 def test_pending_urgent_claims_next_free_slot_without_preempting(self):
  store=fixtures.MemoryEditorialStore(fixtures.documents(count=2))
  service=NewsService(store,clock=lambda:self.now,lease_seconds=120)
  before=service.preview()["next_jobs"]
  self.assertEqual(len(before),2)
  event=before[1]["event_id"]
  action={"action_id":"e"*32,"event_id":event,"revision":1,"action":"urgent"}
  self.assertTrue(service.apply_action(action)["verified"])
  self.assertTrue(service.apply_action(action)["replay"])
  self.assertEqual(service.preview()["next_jobs"][0]["event_id"],event)
  first=service.claim("urgent-worker","private-token-urgent-123456789012345")["job"]
  self.assertEqual(first["event_id"],event)
  self.assertEqual(first["priority"],"urgent")
  self.assertTrue(service.apply_action({**action,"action_id":"a"*32})["stale"])
  self.assertTrue(service.apply_action({**action,"action_id":"b"*32,"action":"dismiss"})["stale"])

class NewsWorkflowTests(unittest.TestCase):
 def setUp(self):
  fixture=fixtures.EditorialStateTests();fixture.setUp()
  captured=fixture.captured();record=fixture.ready_record(captured)
  fixture.service.complete(captured["job"]["job_id"],"worker-1",fixture.token,record)
  self.store=fixture.store;self.now=fixture.now
  self.service=NewsService(self.store,clock=lambda:self.now)
  self.event=captured["job"]["event_id"];self.record=record
  self.token="private-news-image-token-1234567890"
 def action(self,kind,key="a"*32,**extra):
  return self.service.apply_action({"action_id":key,"event_id":self.event,"revision":1,"action":kind,**extra})
 def claim(self,worker="image-one"):
  return self.service.image("claim",worker_id=worker,token=self.token)
 def prepare(self):
  result=self.claim();job=result["job"]
  return self.service.image("prepare",worker_id="image-one",token=self.token,job_id=job["job_id"],
   command_id="news-img-command",prompt_sha256="b"*64,
   session={"session_id":"local","private_journal_id":"local","conversation_url_sha256":"c"*64})
 def test_pub_archives_preserving_original_record_and_idempotence(self):
  original=copy.deepcopy(self.record);self.assertTrue(self.action("archive")["verified"])
  _,docs=self.store.read_editorial_snapshot()
  self.assertEqual(docs[ed.PREFIX+"news/"+self.event+".json"]["status"],"archived")
  self.assertEqual(docs[ed.PREFIX+"records/"+self.event+"/r1.json"],original)
  self.assertTrue(self.action("archive")["replay"]);self.assertIsNone(self.claim()["job"])
 def test_rework_creates_new_fifo_revision_without_replacing_record(self):
  self.action("rework_x",hints="Buscar la declaración original en X y contrastarla.")
  _,docs=self.store.read_editorial_snapshot()
  self.assertEqual(docs[ed.PREFIX+"news/"+self.event+".json"]["current_revision"],2)
  jid=self.event+"-r2-editorial";self.assertEqual(docs[ed.job_path(jid)]["status"],"pending")
  self.assertEqual(docs[ed.PREFIX+"records/"+self.event+"/r1.json"],self.record)
 def test_image_claim_is_global_and_never_reuses_existing_attempt(self):
  one=self.claim();self.assertEqual(one["job"]["event_id"],self.event)
  self.assertIsNone(self.claim("image-two")["job"])
  self.assertTrue(self.claim()["replay"])
 def test_uncertain_prepare_never_authorizes_resend(self):
  self.claim();self.store.lose_response=True
  self.assertFalse(self.prepare()["send_authorized"])
  self.assertFalse(self.service.image("prepare",worker_id="image-one",token=self.token,
   job_id=self.event+"-r1-image",command_id="changed",prompt_sha256="d"*64,session={})["send_authorized"])
 def test_wrong_owner_cannot_heartbeat(self):
  self.claim()
  with self.assertRaises(ed.EditorialError):
   self.service.image("heartbeat",worker_id="other",token=self.token,job_id=self.event+"-r1-image")
 def test_incident_does_not_block_other_editorial_news(self):
  job=self.prepare()["job"]
  self.service.image("fail",worker_id="image-one",token=self.token,job_id=job["job_id"],code="NEWS_IMAGE_CAPTURE_TIMEOUT")
  _,docs=self.store.read_editorial_snapshot()
  self.assertEqual(docs[ed.INDEX]["items"][self.event]["image_incident"]["code"],"NEWS_IMAGE_CAPTURE_TIMEOUT")
  self.assertEqual(docs[ed.PREFIX+"news/"+self.event+".json"]["status"],"ready")
  self.assertGreater(self.service.preview()["pending_count"],0)
 def test_legacy_image_recovery_starts_fresh_chat_instead_of_waiting_forever(self):
  job=self.prepare()["job"]
  self.service.image("fail",worker_id="image-one",token=self.token,job_id=job["job_id"],
                     code="NEWS_SUBMISSION_UNCONFIRMED_NO_RESEND")
  path=image_path(self.event,1)
  self.store.commits[self.store.current][path]["problem"]["retry_mode"]="recover_same_chat"
  self.assertEqual(self.service.image_preview()["pending_count"],1)
  retry=self.service.image("claim",worker_id="image-two",token="new-private-image-token-123456789012345")
  self.assertEqual(retry["job"]["attempts"]["claim_count"],2)
  self.assertIsNone(retry["job"]["send_intent"])
  self.assertIsNone(retry["job"]["session"])
 def test_image_cleanup_and_disk_problems_cannot_auto_retry(self):
  for code in ("NEWS_IMAGE_CLEANUP_UNVERIFIED","NEWS_DISK_SPACE_LOW_NO_NEW_CHROME"):
   bad={"status":"problematic","lease":None,"problem":{"code":code,"retry_mode":"recover_same_chat"},
        "attempts":{"claim_count":1,"max_safe_preflight_attempts":3}}
   self.assertFalse(self.service._fresh_image_retry_eligible(bad))
 def test_manual_image_retry_ignores_auto_ceiling_but_starts_fresh_job(self):
  for attempt in range(3):
   worker="image-retry-"+str(attempt)
   job=self.claim(worker)["job"]
   self.assertEqual(job["attempts"]["claim_count"],attempt+1)
   self.service.image("fail",worker_id=worker,token=self.token,job_id=job["job_id"],
                      code="NEWS_IMAGE_CAPTURE_TIMEOUT",cleanup_verified=True)
   self.now+=timedelta(minutes=1)
  path=image_path(self.event,1)
  _,docs=self.store.read_editorial_snapshot();failed=docs[path]
  self.assertEqual(failed["problem"]["retry_mode"],"manual_only")
  self.assertFalse(self.service._fresh_image_retry_eligible(failed))
  self.assertEqual(self.service.image_preview()["pending_count"],0)
  request={"action_id":"b"*32,"event_id":self.event,"revision":1,"action":"retry_image",
           "incident_at":failed["problem"]["at"]}
  self.service.controls({"preferences":[],"actions":[request]})
  self.assertEqual(self.service.image_preview()["pending_count"],1)
  next_job=self.claim("image-manual")["job"]
  self.assertEqual(next_job["policy"]["mode"],"manual_request")
  self.assertEqual(next_job["policy"]["reason"],"retry_image:"+request["action_id"])
  self.assertEqual(next_job["attempts"]["claim_count"],4)
  self.assertEqual(len(next_job["attempts"]["history"]),3)
  self.assertIsNone(next_job["send_intent"])
  self.assertIsNone(next_job["session"])
  self.service.image("fail",worker_id="image-manual",token=self.token,job_id=next_job["job_id"],
                     code="NEWS_IMAGE_CAPTURE_TIMEOUT",cleanup_verified=True)
  self.assertEqual(self.service.image_preview()["pending_count"],0)
  self.assertIsNone(self.claim("image-other")["job"])
  self.now+=timedelta(minutes=1)
  _,docs=self.store.read_editorial_snapshot()
  second={**request,"action_id":"c"*32,"incident_at":docs[path]["problem"]["at"]}
  self.service.controls({"preferences":[],"actions":[request,second]})
  self.assertEqual(self.claim("image-new-manual")["job"]["attempts"]["claim_count"],5)
 def test_manual_image_retry_rejects_stale_incident_and_unsafe_cleanup(self):
  first=self.claim()["job"]
  self.service.image("fail",worker_id="image-one",token=self.token,job_id=first["job_id"],
                     code="NEWS_IMAGE_CAPTURE_TIMEOUT",cleanup_verified=False)
  _,docs=self.store.read_editorial_snapshot();problem=docs[image_path(self.event,1)]["problem"]
  self.assertEqual(problem["retry_mode"],"none")
  request={"action_id":"d"*32,"event_id":self.event,"revision":1,
           "action":"retry_image","incident_at":problem["at"]}
  self.service.controls({"preferences":[],"actions":[request]})
  self.assertEqual(self.service.image_preview()["pending_count"],0)
  self.assertIsNone(self.claim("image-two")["job"])
  self.store.commits[self.store.current][image_path(self.event,1)]["problem"]["retry_mode"]="manual_only"
  self.service.controls({"preferences":[],"actions":[{**request,"incident_at":"2020-01-01T00:00:00Z"}]})
  self.assertIsNone(self.claim("image-three")["job"])
 def test_archived_news_allows_inflight_image_for_the_same_revision(self):
  job=self.prepare()["job"];self.action("archive")
  alive=self.service.image("heartbeat",worker_id="image-one",token=self.token,job_id=job["job_id"])
  self.assertEqual(alive["job"]["event_id"],self.event)
  self.assertEqual(self.service.image_preview()["pending_count"],0)
 def test_preferences_skip_manually_associated_image(self):
  self.service.controls({"actions":[],"preferences":[{"event_id":self.event,"revision":1,"manual_image":{"sha256":"f"*64}}]})
  self.assertIsNone(self.claim()["job"])
 def test_completed_control_history_is_read_once_without_replaying_each_action(self):
  from unittest.mock import patch
  action={"action_id":"a"*32,"event_id":self.event,"revision":1,"action":"archive"}
  self.service.apply_action(action);before=len(self.store.writes)
  with patch.object(self.store,"read_editorial_snapshot",wraps=self.store.read_editorial_snapshot) as reads:
   self.service.controls({"actions":[copy.deepcopy(action) for _ in range(100)],"preferences":[]})
   self.assertEqual(reads.call_count,1)
  self.assertEqual(len(self.store.writes),before)
 def test_stale_action_cannot_modify_new_revision(self):
  self.action("rework");result=self.action("archive",key="b"*32)
  self.assertTrue(result["stale"])
 def test_image_dispatch_preview_is_read_only_and_skips_already_claimed_news(self):
  before=len(self.store.writes)
  plan=self.service.image_preview();self.assertEqual(plan["pending_count"],1)
  self.assertEqual(len(self.store.writes),before)
  self.claim()
  plan=self.service.image_preview();self.assertEqual(plan["pending_count"],0);self.assertEqual(plan["active_count"],1)
  self.now+=timedelta(minutes=26)
  self.assertTrue(self.service.image_preview()["maintenance_needed"])
 def test_sweep_skips_saved_image_even_without_prior_image_job(self):
  indexed=self.store.commits[self.store.current][ed.INDEX]["items"][self.event]
  indexed["image"]={"revision":1,"verified":True,"asset_path":"v2/ttittulares/images/original.png"}
  self.assertEqual(self.service.image_preview()["pending_count"],0)
  self.assertIsNone(self.claim()["job"])
  indexed["image"]["revision"]=2
  self.assertEqual(self.service.image_preview()["pending_count"],1)
  self.assertEqual(self.claim()["job"]["event_id"],self.event)
 def test_no_cleanup_no_image_ready(self):
  job=self.prepare()["job"]
  with self.assertRaises(ed.EditorialError):
   self.service.image("save",worker_id="image-one",token=self.token,job_id=job["job_id"],cleanup_verified=False,asset={})
if __name__=="__main__":unittest.main()
