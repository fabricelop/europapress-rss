"""Image lifecycle uses the same service contract with a synthetic owned browser."""
import tempfile, unittest
from pathlib import Path
from unittest.mock import Mock,patch
from . import test_news_workflow_v2 as workflow_tests
from .news_images_v2 import run_one,image_prompt

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
   def close(self):self.cleanup_verified=True
  self.browser=Browser
 def test_failure_keeps_ready_and_never_requeues_same_image(self):
  def fail(*args,**kwargs):raise RuntimeError("NEWS_IMAGE_CAPTURE_TIMEOUT")
  result=run_one(self.service,self.config,browser_factory=self.browser,raster_get=fail)
  self.assertEqual(result["status"],"incident");self.assertTrue(result["cleanup_verified"])
  self.assertEqual(self.instances[0].sent,1)
  self.assertEqual(self.service.preview()["pending_count"],3)
  second=run_one(self.service,self.config,browser_factory=self.browser,raster_get=fail)
  self.assertEqual(second["status"],"idle");self.assertEqual(len(self.instances),1)
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
  self.assertEqual(self.instances[0].sent,1);self.assertTrue(result["cleanup_verified"])
  _,docs=self.service.store.read_editorial_snapshot();item=docs["v2/ttittulares/state/news-index.json"]["items"][self.fixture.event]
  self.assertTrue(item["image"]["verified"]);self.assertEqual(item["image"]["revision"],1)
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
  self.assertIn("news-img-fixture",prompt);self.assertIn(self.fixture.record["tweet"]["text"],prompt)
  self.assertIn("chat nuevo",prompt);self.assertIn("víctimas",prompt)
if __name__=="__main__":unittest.main()
