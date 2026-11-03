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

if __name__=='__main__':unittest.main()
