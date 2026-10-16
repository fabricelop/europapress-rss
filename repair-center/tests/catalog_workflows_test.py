import unittest,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class WorkflowsTest(unittest.TestCase):
 def test_dispatch_from_strict_mapping_matches_catalog(self):
  js=(ROOT/'catalog.mjs').read_text()
  py=(ROOT/'dispatch.py').read_text()
  workflows=set(re.findall(r"workflow:'([^']+)'",js))
  for wf in workflows:self.assertIn(wf,py)
  self.assertEqual(len(workflows),9)
 def test_no_periodic_workflow(self):
  wf=(ROOT/'.github/workflows/repair-center.yml').read_text()
  self.assertIn('workflow_dispatch',wf)
  self.assertNotIn('schedule:',wf)
  self.assertNotIn('push:',wf)
 def test_google_secrets_are_only_server_side(self):
  client=(ROOT/'public/app.js').read_text()
  self.assertNotIn('GOOGLE_CLIENT_SECRET',client)
  self.assertNotIn('GITHUB_TOKEN',client)
  self.assertNotIn('AGENT_KEY',client)
 def test_install_is_isolated(self):
  script=(ROOT/'Install-Repo.ps1').read_text()
  self.assertIn('gh pr create',script)
  self.assertNotIn('git push origin main',script)
if __name__=='__main__':unittest.main()
