import importlib.util
import tempfile
import unittest
from pathlib import Path
from datetime import datetime, timedelta, timezone

spec=importlib.util.spec_from_file_location('guard',Path(__file__).with_name('tt_editorial_run_guard.py'))
g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)

class TextFirstRecovery(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.old=g.ROOT;g.ROOT=Path(self.tmp.name)
  self.now=datetime(2026,11,3,17,tzinfo=timezone.utc)
  self.row={'event_id':'news','revision':1,'status':'PROCESSING','selected_at':(self.now-timedelta(hours=2)).isoformat()}
  g.save('ttittulares/editorial-queue.json',{'items':[self.row]})
  g.save('trends/editorial-queue.json',{'items':[]})
 def tearDown(self):g.ROOT=self.old;self.tmp.cleanup()
 def test_ready_text_without_any_image_or_delivery_ends_recovery(self):
  g.save('ttittulares/prepared.json',{'items':[{'event_id':'news','revision':1,'tweet':{'text':'Texto factual validado'},'image':None}]})
  g.save('telegram/ttittulares-deliveries.json',{'items':[{'event_id':'news','telegram_message_id':99999,'status':'sent','final':False}]})
  self.assertEqual(g.pending('ttittulares'),[])
 def test_image_or_delivery_ack_does_not_hide_unwritten_text(self):
  g.save('telegram/ttittulares-deliveries.json',{'items':[{'event_id':'news','telegram_message_id':99999,'status':'sent','final':True}]})
  self.assertEqual(len(g.pending('ttittulares')),1)
 def test_revision_and_terminal_guards(self):
  g.save('ttittulares/prepared.json',{'items':[{'event_id':'news','revision':1,'tweet':{'text':'Anterior'}}]})
  g.save('ttittulares/editorial-queue.json',{'items':[{**self.row,'revision':2,'status':'UPDATE_PROCESSING'}]})
  self.assertEqual(g.pending('ttittulares')[0]['revision'],2)
  g.save('ttittulares/decisions.json',{'items':[{'event_id':'news','revision':2,'status':'deleted'}]})
  self.assertEqual(g.pending('ttittulares'),[])
 def test_terminal_without_revision_blocks_all_stale_work_for_that_identity(self):
  g.save('ttittulares/editorial-queue.json',{'items':[{**self.row,'revision':4}]})
  g.save('ttittulares/decisions.json',{'items':[{'event_id':'news','status':'deleted'}]})
  self.assertEqual(g.pending('ttittulares'),[])
 def test_retry_cap_never_permanently_abandons_backlog_and_respects_live_editor(self):
  rows=g.pending('ttittulares');first=g.evaluate('ttittulares',self.now,{},rows=rows)
  previous={'backlog_signature':first['backlog_signature'],'attempts':3,'last_request_at':(self.now-timedelta(minutes=20)).isoformat()}
  self.assertFalse(g.evaluate('ttittulares',self.now,previous,rows=rows)['should_dispatch'])
  later=self.now+timedelta(minutes=45)
  self.assertTrue(g.evaluate('ttittulares',later,previous,rows=rows)['should_dispatch'])
  self.assertFalse(g.evaluate('ttittulares',later,previous,rows=rows,run={'status':'RUNNING','updated_at':later.isoformat()})['should_dispatch'])
 def test_trend_explained_is_done_without_grouping_or_image(self):
  row={'id':'trend','revision':0,'status':'preparing','requested_at':self.row['selected_at']}
  g.save('trends/editorial-queue.json',{'items':[row]})
  g.save('trends/telegram-manual-explained.json',{'items':[{'id':'trend','revision':0,'explanation':'Texto validado','editorial_grouping_state':'pending'}]})
  self.assertEqual(g.pending('ttendencias'),[])


 def test_targeted_dispatch_waits_for_one_revision_then_advances(self):
  start=(self.now-timedelta(hours=2)).isoformat()
  rows=[{'id':'a','revision':1,'status':'preparing','requested_at':start},
        {'id':'b','revision':0,'status':'preparing','requested_at':start}]
  g.save('trends/editorial-queue.json',{'items':rows})
  pending=g.pending('ttendencias')
  first=g.evaluate('ttendencias',self.now,{},rows=pending)
  target=pending[0]
  self.assertEqual(target['id'],'a')
  command={'command_id':'tr-target-a','requested_at':(self.now-timedelta(minutes=3)).isoformat(),
           'target_id':'a','target_revision':1}
  pending_run=g.evaluate('ttendencias',self.now,{},command=command,rows=pending)
  self.assertFalse(pending_run['should_dispatch'])
  self.assertFalse(pending_run['previous_target_completed_or_superseded'])
  g.save('trends/editorial-queue.json',{'items':[rows[1]]})
  remaining=g.pending('ttendencias')
  done=g.evaluate('ttendencias',self.now,{},command=command,rows=remaining)
  self.assertTrue(done['previous_target_completed_or_superseded'])
  self.assertTrue(done['should_dispatch'])
  self.assertEqual(done['pending_ids'],['b'])
  # A fresh in-flight editor still blocks dispatch, irrespective of target.
  live=g.evaluate('ttendencias',self.now,{},command=command,rows=remaining,
                  run={'status':'RUNNING','updated_at':self.now.isoformat()})
  self.assertFalse(live['should_dispatch'])

 def test_target_rotation_after_bounded_retry(self):
  start=(self.now-timedelta(hours=1)).isoformat()
  g.save('trends/editorial-queue.json',{'items':[
   {'id':'a','revision':0,'status':'preparing','requested_at':start},
   {'id':'b','revision':1,'status':'update','requested_at':start}]})
  rows=g.pending('ttendencias')
  self.assertEqual([r['id'] for r in rows],['a','b'])
  # Target choice is deterministic and skips the stuck oldest when retried.
  self.assertEqual(rows[0]['id'],'a')
  self.assertEqual(rows[1 % len(rows)]['id'],'b')


 def test_news_targeted_dispatch_advances_when_first_revision_closes(self):
  at=(self.now-timedelta(hours=2)).isoformat()
  g.save('ttittulares/editorial-queue.json',{'items':[
    {'event_id':'a','revision':1,'status':'PROCESSING','selected_at':at},
    {'event_id':'b','revision':0,'status':'PROCESSING','selected_at':at}]})
  rows=g.pending('ttittulares')
  self.assertEqual([r['id'] for r in rows],['a','b'])
  command={'command_id':'tt-one-a','requested_at':(self.now-timedelta(minutes=2)).isoformat(),
           'target_id':'a','target_revision':1}
  wait=g.evaluate('ttittulares',self.now,{},command=command,rows=rows)
  self.assertFalse(wait['previous_target_completed_or_superseded'])
  self.assertFalse(wait['should_dispatch'])
  g.save('ttittulares/prepared.json',{'items':[
    {'event_id':'a','revision':1,'tweet':{'text':'Hechos contrastados'}}]})
  remaining=g.pending('ttittulares')
  self.assertEqual([r['id'] for r in remaining],['b'])
  outcome=g.evaluate('ttittulares',self.now,{},command=command,rows=remaining)
  self.assertTrue(outcome['previous_target_completed_or_superseded'])
  self.assertTrue(outcome['should_dispatch'])

 def test_news_target_rotation_and_strict_revision(self):
  at=(self.now-timedelta(hours=1)).isoformat()
  g.save('ttittulares/editorial-queue.json',{'items':[
    {'event_id':'a','revision':2,'status':'PROCESSING','selected_at':at},
    {'event_id':'b','revision':0,'status':'PROCESSING','selected_at':at}]})
  rows=g.pending('ttittulares')
  previous={'backlog_signature':g.evaluate('ttittulares',self.now,{},rows=rows)['backlog_signature'],
            'attempts':1}
  self.assertEqual(rows[previous['attempts']%len(rows)]['id'],'b')
  stale={'command_id':'tt-rev1','requested_at':(self.now-timedelta(minutes=2)).isoformat(),
         'target_id':'a','target_revision':1}
  outcome=g.evaluate('ttittulares',self.now,previous,command=stale,rows=rows)
  self.assertTrue(outcome['previous_target_completed_or_superseded'])

if __name__=='__main__':unittest.main()
