import unittest
import importlib.util
from pathlib import Path
spec=importlib.util.spec_from_file_location('repair_dispatch',Path(__file__).resolve().parents[1]/'dispatch.py')
d=importlib.util.module_from_spec(spec);spec.loader.exec_module(d)
ID='4ff52653-956d-4440-8c03-09b4ccf8f8de'
class DispatchTest(unittest.TestCase):
 def test_allowed_maps_only_safe(self):
  self.assertEqual(d.ALLOWED['ttittulares.radar'],'radar-no-d1.yml')
  self.assertNotIn('ttittulares.telegram',d.ALLOWED)
  self.assertNotIn('ttittulares.editorial',d.ALLOWED)
 def test_valid_dispatch(self):
  result=[]
  def call(args,**kw):result.append(args)
  d.execute('ttendencias.radar',ID,'fabricelop/europapress-rss',run=call)
  self.assertEqual(result[0][3],'ttendencias-refresh.yml')
  self.assertEqual(result[0][-2:],['--ref','main'])
 def test_reject_injection_and_repository_changes(self):
  for target in ['ttittulares.telegram','; echo pwned','../workflows/foo','ttendencias.editorial']:
   with self.assertRaises(ValueError):d.execute(target,ID,'fabricelop/europapress-rss',run=lambda *a,**kw:None)
  with self.assertRaises(ValueError):d.execute('ttendencias.radar','bad id','fabricelop/europapress-rss',run=lambda *a,**kw:None)
  with self.assertRaises(ValueError):d.execute('ttendencias.radar',ID,'other/repo',run=lambda *a,**kw:None)
if __name__=='__main__':unittest.main()
