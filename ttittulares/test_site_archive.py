import importlib.util,pathlib,unittest
p=pathlib.Path(__file__).with_name('update_site_archive.py');spec=importlib.util.spec_from_file_location('archive',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ArchiveTests(unittest.TestCase):
 def row(self,revision=1):return m.normalize({'event_id':'isolated-test','revision':revision,'title':'Una noticia de prueba aislada','factual_summary':'Texto propio de prueba','prepared_at':'2026-11-01T12:00:00Z'},'a'*40,'2026-11-01T12:01:00Z')
 def test_empty_queue_preserves_archive(self):
  r={};m.merge(r,[self.row()]);m.merge(r,[]);self.assertEqual(len(r),1)
 def test_retries_are_idempotent_and_revisions_survive(self):
  r={};m.merge(r,[self.row()]);m.merge(r,[self.row()]);m.merge(r,[self.row(2)]);self.assertEqual(len(r),2);self.assertEqual(max(v['revision'] for v in r.values()),2)
 def test_image_update_does_not_change_original_date(self):
  r={};row=self.row();m.merge(r,[row]);new=dict(row,date='2026-11-02T15:00:00Z',day='2026-11-02',image={'kind':'ai'});m.merge(r,[new]);self.assertEqual(r[('isolated-test',1)]['date'],row['date'])
 def test_unverified_photo_is_never_accepted(self):
  self.assertIsNone(m.image_for({'archive_image':{'url':'https://example.org/photo.jpg','rights_status':'unverified'}}))
 def test_no_text_is_not_imported(self):
  self.assertIsNone(m.normalize({'event_id':'x','title':'Title'},'a'*40,'2026-11-01T12:00:00Z'))
if __name__=='__main__':unittest.main()
