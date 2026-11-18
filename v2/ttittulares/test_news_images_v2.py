"""Image lifecycle uses the same service contract with a synthetic owned browser."""
import json, tempfile, unittest
from pathlib import Path
from unittest.mock import Mock,patch
from . import test_news_workflow_v2 as workflow_tests
from .news_images_v2 import run_one,image_prompt,image_health,check

class NewsImageLifecycleTests(unittest.TestCase):
 def setUp(self):
  self.fixture=workflow_tests.NewsWorkflowTests();self.fixture.setUp();self.service=self.fixture.service
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
  self.config={"root":Path(self.temp.name),"chrome":Path("chrome.exe"),"seed":Path("AuthSeed")}
  self.instances=[]
  owner=self
  class Browser:
   def __init__(self,**kwargs):self.kwargs=kwargs;self.cleanup_verified=False;self.sent=0;self.page=Mock();owner.instances.append(self)
   def open(self):pass
   def send_once(self,prompt):self.sent+=1;self.prompt=prompt
   def confirm_submission(self,*args):return "https://chatgpt.com/c/12345678-1234-1234-1234-123456789012"
   def close(self):self.preserved_at_close=getattr(self,'preserve_profile',False);self.cleanup_verified=True
  self.browser=Browser
 def test_failure_retries_new_image_in_fresh_chats_and_stops_after_three(self):
  def fail(*args,**kwargs):raise RuntimeError("NEWS_IMAGE_CAPTURE_TIMEOUT")
  result=run_one(self.service,self.config,browser_factory=self.browser,raster_get=fail)
  self.assertEqual(result["status"],"incident");self.assertTrue(result["cleanup_verified"])
  self.assertEqual(self.instances[0].sent,1)
  self.assertFalse(self.instances[0].preserved_at_close)
  self.assertEqual(self.service.preview()["pending_count"],3)
  self.assertEqual(self.service.image_preview()["pending_count"],1)
  for attempt in (2,3):
   again=run_one(self.service,self.config,browser_factory=self.browser,raster_get=fail)
   self.assertEqual(again["status"],"incident")
   self.assertEqual(len(self.instances),attempt)
   self.assertEqual(self.instances[-1].sent,1)
   self.assertNotEqual(self.instances[-1].kwargs["profile"],self.instances[-2].kwargs["profile"])
  self.assertEqual(run_one(self.service,self.config,browser_factory=self.browser,raster_get=fail)["status"],"idle")
  self.assertEqual(len(self.instances),3)
  _,docs=self.service.store.read_editorial_snapshot()
  job=docs["v2/ttittulares/jobs/images/"+self.fixture.event+"-r1-image.json"]
  self.assertEqual(job["attempts"]["claim_count"],3)
  self.assertEqual(job["attempts"]["submission_count"],3)
  self.assertEqual([x["outcome"] for x in job["attempts"]["history"]],["failed_after_submit"]*3)
  self.assertEqual(len({x["command_id"] for x in job["attempts"]["history"]}),3)
  self.assertEqual(job["problem"]["retry_mode"],"manual_only")
 def test_unverified_cleanup_blocks_retry_and_keeps_incident(self):
  class UnsafeBrowser(self.browser):
   def close(self):self.cleanup_verified=False
  run_one(self.service,self.config,browser_factory=UnsafeBrowser,
   raster_get=lambda *args,**kwargs: (_ for _ in ()).throw(RuntimeError("NEWS_IMAGE_CAPTURE_TIMEOUT")))
  self.assertEqual(self.service.image_preview()["pending_count"],0)
  self.assertEqual(run_one(self.service,self.config,browser_factory=self.browser)["status"],"idle")
 def test_success_binds_original_only_after_owned_cleanup(self):
  from PIL import Image
  import io,random
  data=random.Random(123).randbytes(1024*576*3);output=io.BytesIO()
  Image.frombytes("RGB",(1024,576),data).save(output,format="PNG");raw=output.getvalue()
  def save_raster(data,event_id,revision,meta):
   self.assertTrue(self.instances[0].cleanup_verified);self.assertEqual(data,raw)
   return "v2/ttittulares/images/"+event_id+"-r1-"+meta["sha256"][:24]+".png","a"*40
  self.service.store.save_raster=save_raster
  result=run_one(self.service,self.config,browser_factory=self.browser,raster_get=lambda *a,**k:raw)
  self.assertEqual(result["status"],"saved");self.assertTrue(result["verified"])
  self.assertTrue(result["local_original_reclaimed"])
  self.assertEqual(list((self.config["root"]/"image-originals").glob("*.bin")),[])
  self.assertEqual(self.instances[0].sent,1);self.assertTrue(result["cleanup_verified"])
  _,docs=self.service.store.read_editorial_snapshot();item=docs["v2/ttittulares/state/news-index.json"]["items"][self.fixture.event]
  self.assertTrue(item["image"]["verified"]);self.assertEqual(item["image"]["revision"],1)
 def test_image_started_in_elab_completes_after_move_to_archive(self):
  data=b"\x00"*12001  # Synthetic bytes; metadata and storage are both mocked.
  sha="e"*64
  meta={"sha256":sha,"mime":"image/png","width":1024,"height":640,"size":len(data)}
  self.service.store.save_raster=lambda *args:("v2/ttittulares/images/archived-original.png","a"*40)
  def after_archive(*args,**kwargs):
   action={"action_id":"e"*32,"event_id":self.fixture.event,"revision":1,"action":"archive"}
   self.assertTrue(self.service.apply_action(action)["verified"])
   return data
  with patch("v2.ttittulares.news_images_v2.raster_metadata",return_value=meta):
   result=run_one(self.service,self.config,browser_factory=self.browser,raster_get=after_archive)
  self.assertEqual(result["status"],"saved")
  _,docs=self.service.store.read_editorial_snapshot()
  self.assertEqual(docs["v2/ttittulares/news/"+self.fixture.event+".json"]["status"],"archived")
  self.assertTrue(docs["v2/ttittulares/state/news-index.json"]["items"][self.fixture.event]["image"]["verified"])
  self.assertEqual(run_one(self.service,self.config,browser_factory=self.browser)["status"],"idle")
 def test_no_new_image_job_is_started_for_an_already_archived_news(self):
  self.service.apply_action({"action_id":"f"*32,"event_id":self.fixture.event,"revision":1,"action":"archive"})
  self.assertEqual(self.service.image_preview()["pending_count"],0)
  self.assertEqual(run_one(self.service,self.config,browser_factory=self.browser)["status"],"idle")
 def test_image_probe_does_not_write_heartbeat_on_every_poll(self):
  def probes(page,*args,**kwargs):
   for _ in range(3):page.evaluate("probe")
   raise RuntimeError("NEWS_IMAGE_CAPTURE_TIMEOUT")
  with patch.object(self.service,"image",wraps=self.service.image) as calls:
   with patch("v2.ttittulares.news_images_v2.time.monotonic",side_effect=[100,101,102,103]):
    run_one(self.service,self.config,browser_factory=self.browser,raster_get=probes)
   self.assertNotIn("heartbeat",[c.args[0] for c in calls.call_args_list])
 def test_prompt_is_self_contained_and_exact_revision(self):
  prompt=image_prompt(self.fixture.record,"news-img-fixture")
  self.assertIn(self.fixture.event,prompt);self.assertIn('"revision": 1',prompt)
  self.assertIn("news-img-fixture",prompt);self.assertIn(self.fixture.record["explanation"],prompt)
  self.assertIn("CHAT NUEVO",prompt);self.assertIn("UNA SOLA imagen GAG",prompt)
  self.assertIn("víctimas",prompt);self.assertIn("no dibujes guindillas",prompt)
 def test_unconfirmed_prepare_never_sends_and_keeps_journal_honest(self):
  original=self.service.image
  def unconfirmed(operation,**kwargs):
   if operation=="prepare":return {"send_authorized":False,"reason":"NEWS_IMAGE_PREPARE_UNVERIFIED"}
   return original(operation,**kwargs)
  with patch.object(self.service,"image",side_effect=unconfirmed):
   result=run_one(self.service,self.config,browser_factory=self.browser)
  self.assertEqual(result["status"],"incident")
  self.assertEqual(result["code"],"NEWS_IMAGE_PREPARE_UNVERIFIED")
  self.assertEqual(self.instances[0].sent,0)
  journal=json.loads(next((self.config["root"]/"image-journals").glob("*.json")).read_text())
  self.assertFalse(journal["sent"]);self.assertFalse(journal["intent_durable"])
 def test_daemon_health_is_private_and_contains_no_job_secrets(self):
  image_health(self.config["root"],{"pending_count":3,"active_count":0,
                                     "error_stage":"controls_or_preview","error_code":"HTTPERROR"})
  output=self.config["root"]/"image-daemon-status.json"
  data=json.loads(output.read_text(encoding="utf-8"))
  self.assertEqual(data["kind"],"image_daemon_health")
  self.assertEqual(data["pending_count"],3)
  self.assertEqual(data["error_code"],"HTTPERROR")
  self.assertNotIn("token",output.read_text(encoding="utf-8"))
 def test_check_reads_preferences_without_writing_actions_or_opening_chat(self):
  self.service.store._token="fake-test-only-token"
  with patch("v2.ttittulares.news_images_v2.read_controls",
             return_value={"preferences":[],"actions":[{"action":"archive"}]}) as control:
   with patch.object(self.service,"controls",side_effect=AssertionError("check must be read only")):
    result=check(self.service)
  control.assert_called_once()
  self.assertTrue(result["controls_ok"])
  self.assertEqual(result["image_preview"]["pending_count"],1)
  self.assertEqual(result["published"],False)
if __name__=="__main__":unittest.main()
