"""Prevent GitHub GITHUB_TOKEN refreshes from silently leaving Site Top30 stale."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
INLINE = {
    "ttendencias-refresh.yml": "python3 trends/auto_queue_new.py",
    "ttendencias-editorial-apply.yml": "python3 trends/apply_editorial_outbox.py",
    "ttendencias-editorial-reconcile.yml": "python3 shared/ttendencias_queue_reconcile.py",
    "ttendencias-cleanup-editorial.yml": 'path.write_text(json.dumps(obj,ensure_ascii=False,indent=2)',
}


class SiteFeedWorkflowWiringTest(unittest.TestCase):
    def test_every_radar_editorial_writer_exports_site_feed_before_commit(self):
        for filename, source_action in INLINE.items():
            with self.subTest(filename=filename):
                s = (WORKFLOWS / filename).read_text(encoding="utf-8")
                action = s.index(source_action)
                export = s.index("python3 trends/export_site_top30.py", action)
                stage = s.index("git add ", export)
                self.assertTrue(action < export < stage)
                self.assertTrue(
                    "trends/site-top30-current.json" in s[stage:stage + 240]
                    or s[stage:stage + 30].startswith("git add -A trends"),
                    "Site feed must be staged (explicitly or by git add -A trends)",
                )

    def test_periodic_self_healing_when_bot_commits_skip_push_events(self):
        sync = (WORKFLOWS / "ttendencias-site-top30-sync.yml").read_text(encoding="utf-8")
        self.assertIn("schedule:", sync)
        self.assertIn("cron: '*/5 * * * *'", sync)
        self.assertIn("cancel-in-progress: false", sync)
        self.assertIn("git reset --hard origin/main", sync)
        self.assertIn("feed['radar_captured_at']==recent['captured_at']", sync)
        self.assertIn("expected==published", sync)
        self.assertIn("git add trends/site-top30-current.json", sync)

    def test_export_is_not_only_a_separate_push_trigger(self):
        s = (WORKFLOWS / "ttendencias-refresh.yml").read_text(encoding="utf-8")
        self.assertIn("python3 trends/export_site_top30.py", s)
        self.assertIn("trends/site-top30-current.json", s)
        sync = (WORKFLOWS / "ttendencias-site-top30-sync.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", sync)
        self.assertIn("'trends/recent.json'", sync)
        self.assertIn("'tests/test_site_top30_workflow_wiring.py'", sync)


if __name__ == "__main__":
    unittest.main()
