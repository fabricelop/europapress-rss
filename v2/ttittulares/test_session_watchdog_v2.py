"""No Chrome or Windows needed: exact-profile timeout and cleanup contracts."""
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest

from .editorial_browser_v2 import clone_job_profile
from .session_watchdog_v2 import (
    OwnedSessionWatchdog, enough_space, DISPOSABLE_MARKER,
    reclaim_disposable_sessions, active_news_worker_ids,
)


RUN_ID = 'a' * 32


class FakeProcess:
    def __init__(self, exit_code=None):
        self.exit_code = exit_code
        self.terminated = False

    def poll(self):
        return self.exit_code

    def terminate(self):
        self.terminated = True
        self.exit_code = -15

    def wait(self, timeout=None):
        return self.exit_code


class SessionWatchdogTests(unittest.TestCase):
    def setup_job(self, root, *, image=False, process=None):
        kind = 'image-sessions' if image else 'sessions'
        folder = Path(root) / kind / RUN_ID
        profile = folder / 'Profile'
        profile.mkdir(parents=True)
        (profile / 'large-temp-cache').write_text('private')
        process = process or FakeProcess()
        seen = []
        def cleanup(find):
            seen.append(str(profile))
            self.assertEqual(find(), set())
            return {'closed': True}
        watch = OwnedSessionWatchdog(root, RUN_ID, process, image=image,
                                    find_pids=lambda path: set(), cleanup=cleanup)
        return watch, folder, process, seen

    def test_timeout_stops_only_own_editorial_session(self):
        with tempfile.TemporaryDirectory() as root:
            seed = Path(root) / 'AuthSeed'
            seed.mkdir()
            (seed / 'keep').write_text('auth')
            watch, folder, process, seen = self.setup_job(root)
            watch._deadline()
            self.assertTrue(process.terminated)
            self.assertTrue(watch.timed_out)
            self.assertTrue(watch.cleanup_verified)
            self.assertFalse(folder.exists())
            self.assertEqual(len(seen), 1)
            self.assertEqual((seed / 'keep').read_text(), 'auth')

    def test_crashed_image_worker_reclaims_orphan_without_killing_process(self):
        with tempfile.TemporaryDirectory() as root:
            watch, folder, process, _ = self.setup_job(root, image=True,
                                                        process=FakeProcess(exit_code=1))
            self.assertTrue(watch.finalize()['cleanup_verified'])
            self.assertFalse(process.terminated)
            self.assertFalse(folder.exists())

    def test_unknown_or_linked_directory_is_not_deleted(self):
        with tempfile.TemporaryDirectory() as root:
            foreign = Path(root) / 'important'
            foreign.mkdir()
            (foreign / 'keep').write_text('safe')
            folder = Path(root) / 'sessions' / RUN_ID
            folder.parent.mkdir()
            folder.symlink_to(foreign, target_is_directory=True)
            watch = OwnedSessionWatchdog(root, RUN_ID, FakeProcess(exit_code=1),
                                        find_pids=lambda path: set(),
                                        cleanup=lambda find: {'closed': True})
            outcome = watch.finalize()
            self.assertFalse(outcome['cleanup_verified'])
            self.assertEqual(outcome['error_code'], 'NEWS_SESSION_PATH_UNSAFE')
            self.assertEqual((foreign / 'keep').read_text(), 'safe')

    def test_five_gib_free_blocks_new_sessions(self):
        with tempfile.TemporaryDirectory() as root:
            class Usage:
                free = 5 * 1024 ** 3
            self.assertFalse(enough_space(root, disk_usage=lambda _: Usage()))

    def make_disposable(self, root, *, image=False, run_id=RUN_ID):
        base = Path(root)
        seed = base / 'AuthSeed'
        seed.mkdir(exist_ok=True)
        (seed / 'Local State').write_text('private persistent seed')
        folder = base / ('image-sessions' if image else 'sessions') / run_id
        clone_job_profile(seed, folder / 'Profile', find_pids=lambda _: set())
        journals = base / ('image-journals' if image else 'journals')
        journals.mkdir(exist_ok=True)
        (journals / (run_id + '.json')).write_text('{"private":"journal"}')
        self.assertTrue((folder / DISPOSABLE_MARKER).is_file())
        now = (folder / DISPOSABLE_MARKER).stat().st_mtime + 31 * 60
        return folder, now

    def test_reclaims_proven_crash_orphans_for_editorial_and_images(self):
        for image in (False, True):
            with self.subTest(image=image), tempfile.TemporaryDirectory() as root:
                folder, now = self.make_disposable(root, image=image)
                report = reclaim_disposable_sessions(root, image=image, now=now,
                    active_ids=set(), find_pids=lambda path: set())
                self.assertEqual(report['reclaimed'], 1)
                self.assertFalse(folder.exists())
                self.assertEqual((Path(root) / 'AuthSeed' / 'Local State').read_text(),
                                 'private persistent seed')
                journal = 'image-journals' if image else 'journals'
                self.assertTrue((Path(root) / journal / (RUN_ID + '.json')).is_file())

    def test_active_chrome_and_worker_block_reclaim(self):
        for worker_active, chrome_active in ((True, False), (False, True)):
            with tempfile.TemporaryDirectory() as root:
                folder, now = self.make_disposable(root)
                report = reclaim_disposable_sessions(root, now=now,
                    active_ids={RUN_ID} if worker_active else set(),
                    find_pids=lambda path: {7} if chrome_active else set())
                self.assertEqual(report['reclaimed'], 0)
                self.assertTrue(folder.exists())

    def test_only_exact_marked_sessions_with_journals_are_reaped(self):
        with tempfile.TemporaryDirectory() as root:
            folder, now = self.make_disposable(root)
            marker = folder / DISPOSABLE_MARKER
            journal = Path(root) / 'journals' / (RUN_ID + '.json')
            for edit in ('recent', 'no_marker', 'no_journal', 'foreign_content'):
                with self.subTest(edit=edit):
                    if edit == 'no_marker': marker.unlink()
                    if edit == 'no_journal': journal.unlink()
                    if edit == 'foreign_content': (folder / 'unexpected').write_text('keep')
                    report = reclaim_disposable_sessions(root, now=(0 if edit == 'recent' else now),
                        active_ids=set(), find_pids=lambda path: set())
                    self.assertEqual(report['reclaimed'], 0)
                    self.assertTrue(folder.exists())
                    if edit == 'no_marker': marker.write_text('TTN2_DISPOSABLE_SESSION=' + RUN_ID + '\n')
                    if edit == 'no_journal': journal.write_text('{"private":"journal"}')
                    if edit == 'foreign_content': (folder / 'unexpected').unlink()

    def test_links_and_unmarked_legacy_folders_are_left_alone(self):
        with tempfile.TemporaryDirectory() as root:
            folder, now = self.make_disposable(root)
            marker = folder / DISPOSABLE_MARKER
            marker.unlink()
            marker.symlink_to(Path(root) / 'AuthSeed' / 'Local State')
            report = reclaim_disposable_sessions(root, now=now,
                active_ids=set(), find_pids=lambda path: set())
            self.assertEqual(report['reclaimed'], 0)
            self.assertTrue(folder.exists())
            marker.unlink()  # Pre-hotfix jobs are not auto-reclaimed without a marker.
            report = reclaim_disposable_sessions(root, now=now,
                active_ids=set(), find_pids=lambda path: set())
            self.assertEqual(report['reclaimed'], 0)
            self.assertTrue(folder.exists())

    def test_process_scan_is_strict_and_fail_closed(self):
        def fake(stdout):
            def runner(*args, **kwargs):
                self.assertIn('Get-CimInstance', args[0][-1])
                return SimpleNamespace(returncode=0, stdout=stdout)
            return runner
        command = 'python.exe -m v2.ttittulares.news_images_v2 --run-one --run-id ' + RUN_ID
        self.assertEqual(active_news_worker_ids(True, runner=fake('["' + command + '"]')), {RUN_ID})
        self.assertEqual(active_news_worker_ids(True, runner=fake('[]')), set())
        with self.assertRaisesRegex(RuntimeError, 'LEGACY_WORKER_ACTIVE'):
            active_news_worker_ids(True, runner=fake('["python -m v2.ttittulares.news_images_v2 --run-one"]'))
        with self.assertRaisesRegex(RuntimeError, 'INSPECTION_UNAVAILABLE'):
            active_news_worker_ids(True, runner=fake('not-json'))


if __name__ == '__main__':
    unittest.main()
