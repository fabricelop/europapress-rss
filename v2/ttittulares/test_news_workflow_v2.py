"""Actions, immutable image association and lease regressions; no live browser."""
import copy, unittest
from datetime import timedelta
from . import test_editorial_state_v2 as fixtures
from .news_workflow_v2 import NewsService,image_path
from . import editorial_state_v2 as ed
from .test_radar_ingest_v2 import BASE

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
 def test_archived_news_fences_inflight_image_binding(self):
  job=self.prepare()["job"];self.action("archive")
  with self.assertRaises(ed.EditorialError):
   self.service.image("heartbeat",worker_id="image-one",token=self.token,job_id=job["job_id"])
 def test_preferences_skip_manually_associated_image(self):
  self.service.controls({"actions":[],"preferences":[{"event_id":self.event,"revision":1,"manual_image":{"sha256":"f"*64}}]})
  self.assertIsNone(self.claim()["job"])
 def test_stale_action_cannot_modify_new_revision(self):
  self.action("rework");result=self.action("archive",key="b"*32)
  self.assertTrue(result["stale"])
 def test_no_cleanup_no_image_ready(self):
  job=self.prepare()["job"]
  with self.assertRaises(ed.EditorialError):
   self.service.image("save",worker_id="image-one",token=self.token,job_id=job["job_id"],cleanup_verified=False,asset={})
if __name__=="__main__":unittest.main()
