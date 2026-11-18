"""Verify the actual installer download list forms a self-contained package."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


class InstallPackageTests(unittest.TestCase):
    def test_editorial_repair_updates_only_its_consumer_and_rolls_back_on_failure(self):
        directory=Path(__file__).parent
        repair=(directory/'Repair-News-Editorial-V2.ps1').read_text(encoding='utf-8')
        self.assertIn("'TTActualidadNoticiasV2-Editorial'", repair)
        self.assertIn("'TTN2_EDITORIAL_ENABLED=NO'", repair)
        self.assertIn("'TTN2_EDITORIAL_ENABLED=YES'", repair)
        self.assertIn("'active-code.txt'", repair)
        self.assertIn("'--check'", repair)
        self.assertIn("$switched=$true", repair)
        self.assertIn('if($switched)', repair)
        self.assertIn('TTN2_IMAGE_WINDOWS_TASK_UNCHANGED=YES', repair)
        self.assertIn('NEWS_EDITORIAL_GIT_HASH_MISMATCH=', repair)
        self.assertIn('[string]$ReleaseSha', repair)
        self.assertIn('NEWS_EDITORIAL_REQUESTED_RELEASE_MISMATCH', repair)
        self.assertIn('TTN2_EDITORIAL_DRAIN_WAIT=', repair)
        # The no-queue checks must ship with the repaired editorial release.
        # Otherwise a local probe may silently run old code, or not exist.
        self.assertIn("'probe_news_chat_response_v2.py'", repair)
        self.assertIn("'probe_news_editorial_shape_v2.py'", repair)
        self.assertIn("'probe_news_existing_chat_v2.py'", repair)
        self.assertNotIn("'TTActualidadNoticiasV2-Images'", repair)
        self.assertNotIn("'images.enabled'", repair)
        self.assertNotIn("'image-active-code.txt'", repair)
        self.assertNotIn('Stop-Process', repair)
        self.assertNotIn('Stop-ScheduledTask', repair)
        self.assertNotIn('Remove-Item', repair)
        self.assertNotIn('Kill', repair)

    def test_image_repair_isolated_from_live_editorial_consumer(self):
        directory=Path(__file__).parent
        repair=(directory/'Repair-News-Images-V2.ps1').read_text(encoding='utf-8')
        runner=(directory/'Run-News-Images-Auto.ps1').read_text(encoding='utf-8')
        self.assertIn("'TTActualidadNoticiasV2-Images'",repair)
        self.assertIn("'TTN2_IMAGES_ENABLED=NO'",repair)
        self.assertIn("'TTN2_IMAGES_ENABLED=YES'",repair)
        self.assertIn("'image-active-code.txt'",repair)
        self.assertIn("'image-daemon-status.json'",repair)
        self.assertIn("'--check'",repair)
        self.assertIn("$imageCode=Join-Path $root 'image-active-code.txt'",runner)
        self.assertNotIn("'TTActualidadNoticiasV2-Editorial'",repair)
        self.assertNotIn("'editorial.enabled'",repair)
        self.assertNotIn("Stop-Process",repair)
        self.assertNotIn("Stop-ScheduledTask",repair)
        self.assertNotIn("Remove-Item",repair)
        self.assertNotIn("Kill",repair)

    def test_installer_isolates_old_uncertain_jobs_and_still_verifies_new_pilot(self):
        source = (Path(__file__).parent / 'Install-News-Editorial-V2.ps1').read_text(encoding="utf-8")
        self.assertIn("$queuePreview.preview.blocking_recovery_incident_count -gt 0", source)
        self.assertIn("$null -eq $queuePreview.preview.blocking_recovery_incident_count", source)
        self.assertIn("TTN2_EDITORIAL_UNCERTAIN_INCIDENTS_ISOLATED=", source)
        self.assertIn("TTN2_EDITORIAL_NO_RETRY_OLD_COMMANDS=YES", source)
        self.assertIn("TTN2_EDITORIAL_INCIDENTS_QUARANTINED=", source)
        self.assertNotIn("throw 'Hay un envio incierto", source)
        self.assertNotIn("$queuePreview.preview.recovery_incident_count -gt 0", source)
        self.assertIn("'--run-one'", source)
        self.assertIn("$pilot.cleanup_verified", source)

    def test_download_manifest_contains_every_runtime_and_test_dependency(self):
        news = Path(__file__).parent
        source = (news / 'Install-News-Editorial-V2.ps1').read_text(encoding="utf-8")
        blocks = {key: re.search(r'\$' + key + r'=@\((.*?)\)\s*\n', source, re.S).group(1)
                  for key in ('news', 'shared')}
        files = [('ttittulares', x) for x in re.findall(r"'([^']+)'", blocks['news'])]
        files += [('ttendencias', x) for x in re.findall(r"'([^']+)'", blocks['shared'])]
        command = re.search(r"Invoke-NewsPython -arguments @\('-m','unittest',(.*?)\)\n", source).group(1)
        modules = re.findall(r"'([^']+)'", command)
        self.assertGreaterEqual(len(modules), 5)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for project, name in files:
                src = news.parent / project / name
                dest = root / 'v2' / project / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dest)
            env = os.environ.copy()
            env.pop('PYTHONPATH', None)
            run = subprocess.run([sys.executable, '-m', 'unittest', *modules], cwd=root,
                                 env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(run.returncode, 0, run.stderr[-5000:])
            for file in ('Install-News-Editorial-V2.ps1', 'Run-News-Editorial-Auto.ps1'):
                self.assertNotIn('Stop-Process', (news / file).read_text(encoding="utf-8"))


if __name__ == '__main__': unittest.main()

