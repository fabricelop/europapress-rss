"""Hard-stop and reclaim only disposable News V2 browser sessions.

The parent daemon supervises the Python child, which can otherwise hang before
its own finally block.  Never touch AuthSeed, shared Chrome, or a user profile.
The independent private journal is intentionally outside the deleted tree.
"""
from __future__ import annotations

from pathlib import Path
import json
import re
import shutil
import subprocess
import threading
import time

from .editorial_browser_v2 import common

SESSION_LIMIT_SECONDS = 480
MIN_NEW_SESSION_FREE_BYTES = 8 * 1024 ** 3
DISPOSABLE_MARKER = 'ttn2-disposable-session.marker'
ORPHAN_MIN_AGE_SECONDS = 30 * 60
ORPHAN_SWEEP_INTERVAL_SECONDS = 10 * 60
SESSION_ID = re.compile(r'[a-f0-9]{32}\Z')


def mark_disposable_profile(profile):
    """Mark only a new, job-owned UUID folder, never AuthSeed or preflight."""
    profile = Path(profile)
    folder = profile.parent
    if (profile.name != 'Profile' or folder.parent.name not in ('sessions', 'image-sessions')
            or not SESSION_ID.fullmatch(folder.name)):
        return False
    marker = folder / DISPOSABLE_MARKER
    # An existing marker means this is not a fresh disposable allocation.
    with marker.open('x', encoding='ascii') as output:
        output.write('TTN2_DISPOSABLE_SESSION=' + folder.name + '\n')
    return True


def active_news_worker_ids(image, *, runner=subprocess.run):
    """Fail closed when Windows cannot prove which News children remain alive."""
    module = ('v2.ttittulares.news_images_v2' if image
              else 'v2.ttittulares.editorial_consumer_v2')
    script = (
        '$ErrorActionPreference="Stop"; '
        '$items=@(Get-CimInstance Win32_Process | Where-Object { '
        '$_.Name -in @("python.exe","pythonw.exe","py.exe") -and '
        '$_.CommandLine -like "*' + module + '*" } | '
        'Select-Object -ExpandProperty CommandLine); '
        'ConvertTo-Json -InputObject $items -Compress'
    )
    result = runner(['powershell.exe', '-NoProfile', '-Command', script],
                    capture_output=True, text=True, timeout=20,
                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    if result.returncode:
        raise RuntimeError('NEWS_ORPHAN_PROCESS_INSPECTION_UNAVAILABLE')
    try:
        payload = json.loads(result.stdout.strip())
    except (ValueError, TypeError):
        raise RuntimeError('NEWS_ORPHAN_PROCESS_INSPECTION_UNAVAILABLE') from None
    if not isinstance(payload, list):
        payload = [payload]
    ids = set()
    for command in payload:
        if not isinstance(command, str) or module not in command:
            raise RuntimeError('NEWS_ORPHAN_PROCESS_INSPECTION_UNAVAILABLE')
        # The daemon itself owns no individual profile. An old unsupervised
        # worker, however, means the orphan scan cannot be trusted.
        if '--daemon' in command and '--run-one' not in command:
            continue
        found = re.search(r'--run-id\s+["\']?([a-f0-9]{32})(?=["\']|\s|$)', command)
        if '--run-one' not in command or found is None:
            raise RuntimeError('NEWS_ORPHAN_LEGACY_WORKER_ACTIVE')
        ids.add(found.group(1))
    return ids


def _is_linked(path):
    if path.is_symlink():
        return True
    # A Windows directory junction is not always reported by is_symlink().
    try:
        return bool(path.lstat().st_file_attributes & 0x400)  # FILE_ATTRIBUTE_REPARSE_POINT
    except AttributeError:
        return False


def reclaim_disposable_sessions(root, *, image=False, now=None, active_ids=None,
                                find_pids=None, min_age=ORPHAN_MIN_AGE_SECONDS):
    """Reap proven abandoned browser *copies*; never touch seeds or journals.

    Marker + UUID + private journal + age + Windows worker process scan +
    exact Chrome profile PID check are all mandatory. A failure retains data.
    """
    root = Path(root).resolve()
    kind = 'image-sessions' if image else 'sessions'
    base = root / kind
    report = {'kind': kind, 'reclaimed': 0, 'skipped': 0, 'error_code': None}
    if not base.is_dir() or _is_linked(base):
        return report
    now = time.time() if now is None else now
    candidates = []
    try:
        for folder in base.iterdir():
            if (not SESSION_ID.fullmatch(folder.name) or not folder.is_dir()
                    or _is_linked(folder)):
                continue
            marker = folder / DISPOSABLE_MARKER
            profile = folder / 'Profile'
            journal = root / ('image-journals' if image else 'journals') / (folder.name + '.json')
            if (not marker.is_file() or _is_linked(marker) or not journal.is_file()
                    or _is_linked(journal) or (profile.exists() and _is_linked(profile))
                    or now - marker.stat().st_mtime < min_age
                    or {entry.name for entry in folder.iterdir()} -
                    {DISPOSABLE_MARKER, 'Profile', 'chrome.stderr.log'}
                    or marker.read_text(encoding='ascii') !=
                    'TTN2_DISPOSABLE_SESSION=' + folder.name + '\n'):
                report['skipped'] += 1
                continue
            candidates.append(folder)
        if not candidates:
            return report
        active = set(active_ids) if active_ids is not None else active_news_worker_ids(image)
        find = find_pids or common('chrome_profile_process_v2').exact_chrome_profile_pids
        for folder in candidates:
            profile = folder / 'Profile'
            if folder.name in active or find(profile):
                report['skipped'] += 1
                continue
            # Re-evaluate the exact target after the potentially slow process scan.
            if (_is_linked(folder) or (profile.exists() and _is_linked(profile))
                    or not (folder / DISPOSABLE_MARKER).is_file()):
                report['skipped'] += 1
                continue
            shutil.rmtree(folder)
            report['reclaimed'] += 1
    except (OSError, ValueError, UnicodeError, RuntimeError) as exc:
        # No best-effort deletion when process enumeration or path proofs fail.
        report['error_code'] = ('NEWS_ORPHAN_PROCESS_INSPECTION_UNAVAILABLE'
                                if isinstance(exc, RuntimeError) else 'NEWS_ORPHAN_SWEEP_UNVERIFIED')
    return report


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
