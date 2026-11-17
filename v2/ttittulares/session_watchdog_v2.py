"""Hard-stop and reclaim only disposable News V2 browser sessions.

The parent daemon supervises the Python child, which can otherwise hang before
its own finally block.  Never touch AuthSeed, shared Chrome, or a user profile.
The independent private journal is intentionally outside the deleted tree.
"""
from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import threading

from .editorial_browser_v2 import common

SESSION_LIMIT_SECONDS = 480
MIN_NEW_SESSION_FREE_BYTES = 8 * 1024 ** 3


def enough_space(root, *, disk_usage=shutil.disk_usage):
    return disk_usage(root).free >= MIN_NEW_SESSION_FREE_BYTES


class OwnedSessionWatchdog:
    def __init__(self, root, run_id, process, *, image=False, seconds=SESSION_LIMIT_SECONDS,
                 find_pids=None, cleanup=None):
        if not re.fullmatch(r'[a-f0-9]{32}', run_id):
            raise ValueError('NEWS_SESSION_ID_INVALID')
        if not 1 <= seconds <= SESSION_LIMIT_SECONDS:
            raise ValueError('NEWS_SESSION_DEADLINE_INVALID')
        self.root = Path(root).resolve()
        self.run_id = run_id
        self.process = process
        self.folder = self.root / ('image-sessions' if image else 'sessions') / run_id
        self.profile = self.folder / 'Profile'
        self.find_pids = find_pids or common('chrome_profile_process_v2').exact_chrome_profile_pids
        self.cleanup = cleanup or common('chrome_cleanup_v2').cleanup_v2_profile
        self.timed_out = False
        self.cleanup_verified = False
        self.error_code = None
        self._lock = threading.Lock()
        # The timer runs while the parent is blocked on a remote queue read.
        self.timer = threading.Timer(seconds, self._deadline)
        self.timer.daemon = True

    def start(self):
        self.timer.start()
        return self

    def _deadline(self):
        with self._lock:
            if self.process.poll() is not None:
                return
            self.timed_out = True
            try:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                pass
            self._clear_profile()

    def _clear_profile(self):
        # Even a crashed child may leave Chrome alive. No broad taskkill or
        # recursive deletion of anything beyond the exact owned UUID folder.
        if self.folder.is_symlink() or self.profile.is_symlink():
            self.error_code = 'NEWS_SESSION_PATH_UNSAFE'
            return
        if self.folder.parent not in (self.root / 'sessions', self.root / 'image-sessions'):
            self.error_code = 'NEWS_SESSION_PATH_UNSAFE'
            return
        if self.process.poll() is None:
            self.error_code = 'NEWS_SESSION_PYTHON_STILL_RUNNING'
            return
        try:
            if self.profile.is_dir():
                result = self.cleanup(lambda: self.find_pids(self.profile))
                if result.get('closed') is not True or self.find_pids(self.profile):
                    self.error_code = 'NEWS_SESSION_CHROME_STILL_RUNNING'
                    return
            if self.folder.is_dir():
                shutil.rmtree(self.folder)
            self.cleanup_verified = True
        except (OSError, RuntimeError):
            self.error_code = 'NEWS_SESSION_CLEANUP_UNVERIFIED'

    def finalize(self):
        self.timer.cancel()
        with self._lock:
            self._clear_profile()
        return {'timed_out': self.timed_out,
                'cleanup_verified': self.cleanup_verified,
                'error_code': self.error_code}
