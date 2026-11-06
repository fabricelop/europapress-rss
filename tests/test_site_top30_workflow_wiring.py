"""Prevent GitHub GITHUB_TOKEN refreshes from silently leaving Site Top30 stale."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
INLINE = {
    "update.yml": "python3 trends/auto_queue_new.py",
    "ttendencias-refresh.yml": "python3 trends/auto_queue_new.py",
    "ttendencias-editorial-apply.yml": "python3 trends/apply_editorial_outbox.py",
    "ttendencias-editorial-reconcile.yml": "python3 shared/ttendencias_queue_reconcile.py",
    "ttendencias-cleanup-editorial.yml": 'path.write_text(json.dumps(obj,ensure_ascii=False,indent=2)',
}


class SiteFeedWorkflowWiringTest(unittest.TestCase):
    def test_active_radar_retry_exports_the_recalculated_snapshot(self):
        """Run the actual persistence shell with a rejected push and new radar.

        Git is a local fake: no network, dispatch, generation or editorial writes.
        The exporter is real, including explanation and image identity selection.
        """
        workflow = (WORKFLOWS / "update.yml").read_text(encoding="utf-8")
        section = workflow.split("- name: Guardar captura TTendencias inmediatamente", 1)[1]
        script = section.split("run: |\n", 1)[1].split("\n      - name:", 1)[0]
        script = "\n".join(line[10:] for line in script.splitlines())
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "trends").mkdir()
            (root / "bin").mkdir()
            shutil.copy(ROOT / "trends/export_site_top30.py", root / "trends/export_site_top30.py")
            shutil.copy(ROOT / "trends/suppression.py", root / "trends/suppression.py")
            shutil.copy(ROOT / "trends/suppressed-terms.json", root / "trends/suppressed-terms.json")
            snapshots = [
                {"captured_at": "2026-11-02T13:00:00+01:00", "top30": ["Alpha"]},
                {"captured_at": "2026-11-02T13:10:00+01:00", "top30": ["Beta"]},
            ]
            (root / "snapshots.json").write_text(json.dumps(snapshots))
            (root / "trends/recent.json").write_text(json.dumps(snapshots[0]))
            for name, value in [("telegram-manual-explained.json", {"items": []}),
                                ("explained.json", {"items": []}),
                                ("requests.json", {"requests": []}),
                                ("site-ai-images.json", {"images": []})]:
                (root / "trends" / name).write_text(json.dumps(value))
            fake_git = '''#!/usr/bin/env python3
import json, pathlib, sys
p=pathlib.Path('.')
a=sys.argv[1:]
if a[0]=='rev-parse': print('baseline')
elif a[0]=='diff': sys.exit(1)
elif a[0]=='add':
    radar=json.loads((p/'trends/recent.json').read_text())
    feed=json.loads((p/'trends/site-top30-current.json').read_text())
    assert 'trends/site-top30-current.json' in a
    assert feed['radar_captured_at']==radar['captured_at']
    assert [x['name'] for x in feed['items']]==radar['top30']
    with (p/'staged.jsonl').open('a') as f: f.write(json.dumps(feed)+'\\n')
elif a[0]=='push':
    if not (p/'push-rejected').exists():
        (p/'push-rejected').touch(); sys.exit(1)
elif a[0]=='reset':
    snapshots=json.loads((p/'snapshots.json').read_text())
    (p/'trends/recent.json').write_text(json.dumps(snapshots[1]))
'''
            (root / "bin/git").write_text(fake_git)
            (root / "bin/sleep").write_text("#!/bin/sh\nexit 0\n")
            for tool in ["git", "sleep"]:
                (root / "bin" / tool).chmod(0o755)
            env = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", "-e", "-c", script], cwd=root, env=env,
                                    text=True, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            staged = [json.loads(line) for line in (root / "staged.jsonl").read_text().splitlines()]
            self.assertEqual([row["radar_captured_at"] for row in staged],
                             [row["captured_at"] for row in snapshots])
            self.assertEqual([row["items"][0]["name"] for row in staged], ["Alpha", "Beta"])

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

