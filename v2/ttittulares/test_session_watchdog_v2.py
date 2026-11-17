"""No Chrome or Windows needed: exact-profile timeout and cleanup contracts."""
from pathlib import Path
import tempfile
import unittest

from .session_watchdog_v2 import OwnedSessionWatchdog, enough_space


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


if __name__ == '__main__':
    unittest.main()
