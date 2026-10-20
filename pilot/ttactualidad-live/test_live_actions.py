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
  self.write('telegram/events.json',{'events':[]})
  self.write('telegram/editorial-processing.json',{'items':[]})
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
 def test_tti_growing_manual_override_three_sources(self):
  self.write('ttittulares/status.json',{'three_source_items':[{
   'event_id':'grow123','revision':2,'title':'Noticia creciendo','source_count':3,
   'sources':['Medio A','Medio B','Medio C']}]})
  self.write('telegram/events.json',{'events':[{
   'id':'grow123','revision':2,'canonical_title':'Noticia creciendo',
   'source_count':3,'status':'WAITING','sources':['Medio A','Medio B','Medio C'],
   'appearances':[{'source':'Medio A','url':'https://a.test/a'}]}]})
  changed,result=app.apply_live('ttittulares','grow123','prepare',2)
  self.assertEqual(result,'applied')
  row=changed['ttittulares/editorial-queue.json']['items'][0]
  self.assertEqual(row['status'],'PROCESSING')
  self.assertEqual(row['selection_mode'],'MANUAL_GROWING_OVERRIDE')
  self.assertEqual(row['source_count'],3)
  self.assertEqual(row['source_evidence'][0]['source'],'Medio A')
  self.assertTrue(row['force_user_elaborate'])
  self.assertTrue(row['manual_threshold_override'])
  self.assertTrue(row['manual_investigation_requested'])
  self.assertIn('telegram/editorial-processing.json',changed)
  self.assertEqual(changed['telegram/editorial-processing.json']['items'][0]['status'],'PROCESSING')
 def test_tti_growing_rejects_stale_revision(self):
  self.write('ttittulares/status.json',{'three_source_items':[{'event_id':'grow123','revision':3}]})
  self.write('telegram/events.json',{'events':[{'id':'grow123','revision':3,
   'status':'WAITING','source_count':3}]})
  with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','grow123','prepare',2)
 def test_tti_growing_rejects_radar_promoted_to_four(self):
  self.write('ttittulares/status.json',{'three_source_items':[{'event_id':'grow123','revision':1}]})
  self.write('telegram/events.json',{'events':[{'id':'grow123','revision':1,
   'status':'ELIGIBLE','source_count':4}]})
  with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','grow123','prepare',1)
 def test_tti_growing_rejects_non_growing_or_terminal(self):
  self.write('telegram/events.json',{'events':[{'id':'grow123','revision':1,
   'status':'WAITING','source_count':3}]})
  with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','grow123','prepare',1)
  self.write('ttittulares/status.json',{'three_source_items':[{'event_id':'grow123','revision':1}]})
  self.write('ttittulares/decisions.json',{'items':[{'event_id':'grow123','status':'deleted'}]})
  with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','grow123','prepare',1)
 def test_tti_growing_idempotent_if_already_processing(self):
  self.write('ttittulares/editorial-queue.json',{'items':[{
   'event_id':'grow123','status':'PROCESSING','revision':1}]})
  self.write('telegram/editorial-processing.json',{'items':[{
   'event_id':'grow123','status':'PROCESSING','revision':1}]})
  changed,result=app.apply_live('ttittulares','grow123','prepare',1)
  self.assertEqual(result,'already_applied')
  self.assertFalse(changed)
 def test_tti_growing_repairs_missing_processing_mirror(self):
  self.write('ttittulares/editorial-queue.json',{'items':[{
   'event_id':'grow123','status':'PROCESSING','revision':1}]})
  changed,result=app.apply_live('ttittulares','grow123','prepare',1)
  self.assertEqual(result,'applied')
  self.assertEqual(list(changed),['telegram/editorial-processing.json'])
  self.assertEqual(changed['telegram/editorial-processing.json']['items'][0]['event_id'],'grow123')
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
 def test_tr_rework_ready_card_from_scratch_and_fresh_photo(self):
  old_photo="https://example.test/old-match-score.jpg"
  self.write('trends/requests.json',{'requests':[{'id':'ferran-test','name':'Ferran',
   'revision':1,'status':'explained','explanation':'Marcador antiguo',
   'closer_text':'Remate antiguo','fallback_image':{'url':old_photo},
   'archive_image':{'url':old_photo},'ai_image':{'url':'https://example.test/old-ai.jpg'},
   'explained_at':'2026-10-20T20:00:00Z'}]})
  self.write('trends/telegram-manual-explained.json',{'items':[{
   'id':'ferran-test','name':'Ferran','revision':1,'status':'explained',
   'explanation':'Marcador antiguo','explained_at':'2026-10-20T20:00:00Z',
   'fallback_image':{'url':old_photo}}]})
  self.write('trends/prepared.json',{'items':[{'id':'ferran-test','revision':1,
   'image':{'url':old_photo}}]})
  self.write('trends/telegram-image-deliveries.json',{'items':[{
   'event_id':'ferran-test','revision':1,'status':'sent'}]})
  changed,result=app.apply_live('ttendencias','ferran-test','rework',1)
  self.assertEqual(result,'applied')
  self.assertFalse(changed['trends/telegram-manual-explained.json']['items'])
  self.assertFalse(changed['trends/prepared.json']['items'])
  req=changed['trends/requests.json']['requests'][0]
  self.assertEqual(req['revision'],2)
  self.assertEqual(req['status'],'preparing')
  self.assertEqual(req['fallback_image_status'],'pending')
  self.assertEqual(req['ai_image_status'],'pending')
  for field in ('explanation','closer_text','fallback_image','archive_image','ai_image','explained_at'):
   self.assertNotIn(field,req)
  self.assertEqual(changed['trends/editorial-queue.json']['items'][0]['revision'],2)
  self.assertEqual(changed['trends/telegram-image-deliveries.json']['items'][0]['status'],'superseded')
  self.assertNotIn(old_photo,str(changed['trends/requests.json']))
 def test_tr_rework_rejects_obsolete_or_already_processing(self):
  self.write('trends/requests.json',{'requests':[{
   'id':'ferran-test','name':'Ferran','revision':2,'status':'explained'}]})
  self.write('trends/telegram-manual-explained.json',{'items':[{
   'id':'ferran-test','name':'Ferran','revision':2,'status':'explained',
   'explanation':'Ultimo texto','explained_at':'2026-10-20T21:00:00Z'}]})
  with self.assertRaises(app.InvalidAction):
   app.apply_live('ttendencias','ferran-test','rework',1)
  self.write('trends/editorial-queue.json',{'items':[{
   'id':'ferran-test','revision':2,'status':'preparing'}]})
  with self.assertRaises(app.InvalidAction):
   app.apply_live('ttendencias','ferran-test','rework',2)
 def test_tr_top30_archived_trend_can_start_a_new_episode(self):
  self.write('trends/recent.json',{'items':[{'name':'Pubill','rank':1}]})
  self.write('trends/requests.json',{'requests':[{
   'id':'pubill-old','name':'Pubill','revision':2,'status':'deleted',
   'explanation':'Partido anterior','archive_image':{'url':'https://example.test/old.jpg'}}]})
  self.write('trends/telegram-manual-explained.json',{'items':[{
   'id':'pubill-old','name':'Pubill','revision':2,'status':'explained',
   'explanation':'Partido anterior','explained_at':'2026-10-13T22:00:00Z'}]})
  self.write('trends/mobile-decisions.json',{'items':[{'id':'pubill-old','status':'deleted'}]})
  changed,result=app.apply_live('ttendencias','pubill-old','rework',2)
  self.assertEqual(result,'applied')
  old,new=changed['trends/requests.json']['requests']
  self.assertEqual((old['id'],old['status']),('pubill-old','deleted'))
  self.assertNotEqual(new['id'],'pubill-old')
  self.assertEqual((new['name'],new['status'],new['revision']),('Pubill','preparing',0))
  self.assertNotIn('explanation',new)
  self.assertNotIn('archive_image',new)
  self.assertEqual(changed['trends/editorial-queue.json']['items'][0]['id'],new['id'])
 def test_tr_top30_group_member_can_rework_independently(self):
  self.write('trends/recent.json',{'items':[{'name':'Joan García','rank':5}]})
  self.write('trends/requests.json',{'requests':[{
   'id':'joan-old','name':'Joan García','revision':0,'status':'explained',
   'group_leader_id':'ferran-old','explanation':'Explicación compartida'}]})
  self.write('trends/telegram-manual-explained.json',{'items':[{
   'id':'ferran-old','name':'Ferran','revision':1,'status':'explained',
   'explanation':'Explicación compartida','trend_names':['Joan García','Ferran']}]})
  changed,result=app.apply_live('ttendencias','joan-old','rework',0)
  self.assertEqual(result,'applied')
  reqs=changed['trends/requests.json']['requests']
  self.assertEqual(len(reqs),2)
  self.assertEqual(reqs[-1]['name'],'Joan García')
  self.assertEqual(reqs[-1]['status'],'preparing')
  self.assertEqual(len(changed['trends/telegram-manual-explained.json']['items']),1)
 def test_tremending_remove_one_and_preserve_checkpoint(self):
  url1='https://www.publico.es/tremending/noticia-prueba-1.html'
  url2='https://www.publico.es/tremending/noticia-prueba-2.html'
  self.write('ttittulares/tremending/items.json',{'scan':{'seen_urls':[url2]},
   'items':[{'id':'tremending-abc123','url':url1,'title':'Primera','status':'pending'},
            {'id':'tremending-def456','url':url2,'title':'Segunda','status':'pending'}]})
  changed,result=app.apply_live('ttittulares','tremending-abc123','deleted',0)
  self.assertEqual(result,'applied')
  items=changed['ttittulares/tremending/items.json']['items']
  self.assertEqual([x['id'] for x in items],['tremending-def456'])
  self.assertIn(url1,changed['ttittulares/tremending/items.json']['scan']['seen_urls'])
  self.assertIn(url2,changed['ttittulares/tremending/items.json']['scan']['seen_urls'])
  self.assertEqual(changed['ttittulares/decisions.json']['items'][0]['status'],'deleted')
  self.assertNotIn('ttittulares/prepared.json',changed)
  self.assertNotIn('telegram/editorial-processing.json',changed)
 def test_tremending_repeat_is_idempotent(self):
  self.write('ttittulares/tremending/items.json',{'items':[]})
  self.write('ttittulares/decisions.json',{'items':[
   {'event_id':'tremending-abc123','status':'deleted'}]})
  changed,result=app.apply_live('ttittulares','tremending-abc123','deleted',0)
  self.assertEqual(result,'already_applied')
  self.assertFalse(changed)
 def test_tremending_rejects_unknown_stale_and_other_actions(self):
  url='https://www.publico.es/tremending/noticia-prueba.html'
  self.write('ttittulares/tremending/items.json',{'items':[
   {'id':'tremending-abc123','url':url,'status':'pending','revision':4}]})
  for action in ('prepare','discard'):
   with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','tremending-abc123',action,4)
  with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','tremending-abc123','deleted',3)
  with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','tremending-other','deleted',0)
 def test_tremending_no_url_does_not_mutate(self):
  self.write('ttittulares/tremending/items.json',{'items':[
   {'id':'tremending-abc123','status':'pending'}]})
  with self.assertRaises(app.InvalidAction):app.apply_live('ttittulares','tremending-abc123','deleted',0)
 def test_only_editorial_processing_no_telegram_callbacks_or_tremending(self):
  self.write('ttittulares/status.json',{'problematic_items':[{'event_id':'abc123','revision':1}]})
  changed,_=app.apply_live('ttittulares','abc123','prepare',1)
  self.assertEqual(set(changed),{'ttittulares/editorial-queue.json','telegram/editorial-processing.json'})
if __name__=='__main__':unittest.main()
