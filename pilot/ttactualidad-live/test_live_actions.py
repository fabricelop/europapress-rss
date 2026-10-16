import importlib.util, json, tempfile, unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('app',Path(__file__).parents[1]/'apply-ttactualidad-action.py')
app=importlib.util.module_from_spec(spec);spec.loader.exec_module(app)
class LiveEditorialTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.original=app.ROOT;app.ROOT=Path(self.tmp.name)
  self.addCleanup(lambda:setattr(app,'ROOT',self.original))
  self.write('ttittulares/editorial-queue.json',{'items':[]})
  self.write('ttittulares/status.json',{'processing_items':[],'problematic_items':[],'three_source_items':[]})
  self.write('ttittulares/decisions.json',{'items':[]})
  self.write('ttittulares/prepared.json',{'items':[]})
  self.write('trends/editorial-queue.json',{'items':[]})
  self.write('trends/requests.json',{'requests':[]})
  self.write('trends/mobile-decisions.json',{'items':[]})
  self.write('trends/telegram-manual-explained.json',{'items':[]})
  self.write('trends/telegram-image-deliveries.json',{'items':[]})
 def write(self,p,d):
  f=app.ROOT/p;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(json.dumps(d),encoding='utf8')
 def test_tti_discard_live_prevents_ready(self):
  self.write('ttittulares/status.json',{'processing_items':[{'event_id':'abc123','title':'Noticia'}]})
  self.write('ttittulares/editorial-queue.json',{'items':[{'event_id':'abc123','revision':1,'status':'PROCESSING'}]})
  changed,result=app.apply_live('ttittulares','abc123','discard',1)
  self.assertEqual(result,'applied')
  self.assertEqual(changed['ttittulares/decisions.json']['items'][0]['status'],'published')
  self.assertEqual(changed['ttittulares/editorial-queue.json']['items'][0]['status'],'PUBLISHED')
 def test_tti_problematic_manual_prepare(self):
  self.write('ttittulares/status.json',{'problematic_items':[{'event_id':'abc123','title':'Prueba','revision':1,'source_count':4}]})
  changed,result=app.apply_live('ttittulares','abc123','prepare',1)
  self.assertEqual(result,'applied')
  item=changed['ttittulares/editorial-queue.json']['items'][0]
  self.assertEqual(item['status'],'PROCESSING')
  self.assertTrue(item['force_user_elaborate'])
  self.assertEqual(item['selection_mode'],'MANUAL_REOPEN_OUTCOME')
 def test_tti_stale_prepare_rejected(self):
  self.write('ttittulares/status.json',{'problematic_items':[{'event_id':'abc123','revision':2}]})
  with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','abc123','prepare',1)
 def test_tr_discard_real_not_simulation(self):
  self.write('trends/editorial-queue.json',{'items':[{'id':'tr123','revision':1,'status':'preparing'}]})
  self.write('trends/requests.json',{'requests':[{'id':'tr123','revision':1,'status':'preparing'}]})
  changed,result=app.apply_live('ttendencias','tr123','discard',1)
  self.assertEqual(result,'applied')
  self.assertEqual(changed['trends/mobile-decisions.json']['items'][0]['status'],'published')
  self.assertEqual(changed['trends/editorial-queue.json']['items'][0]['status'],'published')
 def test_tr_discard_stale_rejected(self):
  self.write('trends/editorial-queue.json',{'items':[{'id':'tr123','revision':4,'status':'preparing'}]})
  with self.assertRaises(app.InvalidAction):app.apply_live('ttendencias','tr123','discard',3)
 def test_tr_prepare_real(self):
  self.write('trends/requests.json',{'requests':[{'id':'tr123','name':'Tendencia','revision':2,'status':'inactive'}]})
  changed,result=app.apply_live('ttendencias','tr123','prepare',2)
  self.assertEqual(result,'applied')
  self.assertEqual(changed['trends/editorial-queue.json']['items'][0]['status'],'preparing')
 def test_no_telegram_or_tremending_writes(self):
  self.write('ttittulares/status.json',{'problematic_items':[{'event_id':'abc123','revision':1}]})
  changed,_=app.apply_live('ttittulares','abc123','prepare',1)
  self.assertTrue(all('telegram/' not in p and 'tremending' not in p and 'selorecordamos' not in p for p in changed))
if __name__=='__main__':unittest.main()
