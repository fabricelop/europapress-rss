"""One owned Chrome process/profile and one fresh ChatGPT conversation per news job.

No API billing, no shared CDP, no persistent browser. Importing opens nothing.
Private profile/journal data never goes to GitHub. Windows runtime only.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
from urllib.request import urlopen

COMPOSERS = ('#prompt-textarea', '[data-testid="prompt-textarea"]',
             '[contenteditable="true"][role="textbox"]')
STOP = '[data-testid="stop-button"],button[aria-label*="Stop"],button[aria-label*="Detener"]'
# The same account can open a fresh conversation under a custom GPT route.
# Its identity still has to be proven from exactly one USER turn below.
CHAT = re.compile(r'https://chatgpt\.com/(?:c/[A-Za-z0-9-]+|g/[A-Za-z0-9_-]+/c/[A-Za-z0-9-]+)/?\Z')
AUTHENTICATED_SESSION = '''async () => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10000);
    try {
        const response = await fetch('/api/auth/session', {
            credentials: 'include', signal: controller.signal, cache: 'no-store'
        });
        if (!response.ok) return false;
        const session = await response.json();
        return Boolean(session && session.user && session.user.id);
    } catch (_) { return false; }
    finally { clearTimeout(timer); }
}'''


def common(name):
    path = Path(__file__).resolve().parent.parent / 'ttendencias' / (name + '.py')
    spec = importlib.util.spec_from_file_location('news_shared_' + name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError('NEWS_SHARED_MODULE_MISSING')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_private(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    with temp.open('w', encoding='utf-8') as file:
        os.chmod(temp, 0o600)
        json.dump(data, file, ensure_ascii=False, indent=2)
        file.flush()
        os.fsync(file.fileno())
    temp.replace(path)


def ignore_cache(directory, names):
    excluded = {'Cache', 'Code Cache', 'GPUCache', 'GrShaderCache', 'ShaderCache',
                'Crashpad', 'component_crx_cache', 'DevToolsActivePort',
                'SingletonLock', 'SingletonCookie', 'SingletonSocket', 'lockfile',
                'Sessions', 'Current Session', 'Current Tabs', 'Last Session', 'Last Tabs'}
    return [name for name in names if name in excluded]


def clone_job_profile(seed, destination, *, find_pids):
    seed, destination = Path(seed).resolve(), Path(destination).resolve()
    if not seed.is_dir() or not (seed / 'Local State').is_file():
        raise RuntimeError('NEWS_AUTH_SEED_MISSING')
    if destination == seed or seed in destination.parents or destination in seed.parents:
        raise RuntimeError('NEWS_PROFILE_PATH_OVERLAP')
    if find_pids(seed):
        raise RuntimeError('NEWS_AUTH_SEED_BROWSER_BUSY')
    if destination.exists():
        raise RuntimeError('NEWS_JOB_PROFILE_ALREADY_EXISTS')
    # Refuse new browser allocations before Windows reaches zero free space.
    # This is only a guard; profiles must still be removed after every job.
    if shutil.disk_usage(seed).free < 3 * 1024**3:
        raise RuntimeError('NEWS_DISK_SPACE_LOW_NO_NEW_CHROME')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.mkdir(exist_ok=False)
    try:
        # A later supervisor restart can reclaim this exact disposable copy
        # after a crash. Persistent AuthSeed and preflight are never marked.
        from .session_watchdog_v2 import mark_disposable_profile
        mark_disposable_profile(destination)
        shutil.copytree(seed, destination, ignore=ignore_cache, dirs_exist_ok=True)
        # Detect a concurrent launch during copying. Never use an uncertain copy.
        if find_pids(seed):
            raise RuntimeError('NEWS_AUTH_SEED_CHANGED_DURING_COPY')
    except Exception:
        # The old code left gigabyte-sized half-copies after a failed clone.
        # Only remove the directory created above, and never an active profile.
        try:
            if not find_pids(destination):
                shutil.rmtree(destination)
        except Exception:
            pass
        raise
    return destination


def read_news_turns(page):
    """Prefer role DOM; use bounded localized transcript only if roles are absent."""
    users = page.locator('[data-message-author-role="user"]').all_text_contents()
    answers = page.locator('[data-message-author-role="assistant"]').all_text_contents()
    if users:
        return users, answers
    # Some ChatGPT layouts expose user bubbles without the role attribute.
    # Never inspect assistant prose for submission identity: an echo is not a send.
    try:
        bubbles = page.locator('[data-user-message-bubble="true"]').all_text_contents()
        if bubbles:
            return bubbles, answers
    except Exception:
        pass
    try:
        body = page.locator('body').inner_text(timeout=4500)
    except Exception:
        return [], answers
    user_markers = list(re.finditer(r'(?m)^\s*(?:You said|Tú dijiste|Has dicho):\s*$', body))
    if len(user_markers) != 1:
        return [], answers
    start = user_markers[0].end()
    assistant = re.search(r'(?m)^\s*(?:ChatGPT said|ChatGPT dijo|ChatGPT ha dicho|ChatGPT respondió):\s*$', body[start:])
    if assistant is None:
        return [], answers
    end = start + assistant.start()
    response = body[start + assistant.end():].strip()
    return [body[start:end].strip()], answers or ([response] if response else [])


def fresh_turn(user_turns, event_id, revision, command_id):
    if len(user_turns) != 1:
        return False
    text = user_turns[0]
    revision_match = re.search(r'"revision"\s*:\s*' + str(revision) + r'\s*[,}]', text)
    return event_id in text and command_id in text and bool(revision_match)


def authenticated_session(page):
    """Return only a boolean: never transfer session objects/tokens to Python."""
    try:
        return page.evaluate(AUTHENTICATED_SESSION) is True
    except Exception:
        raise RuntimeError('NEWS_CHATGPT_AUTH_CHECK_UNAVAILABLE') from None


def listener_process_ids(port, *, runner=subprocess.run):
    """Read the Windows PIDs serving this exact IPv4 loopback CDP endpoint."""
    if type(port) is not int or not 1024 <= port <= 65535 or port in (9223, 9234):
        raise RuntimeError('NEWS_CDP_PORT_INVALID')
    script = ('$ErrorActionPreference="Stop"; @(' +
        'Get-NetTCPConnection -State Listen -LocalPort ' + str(port) +
        ' -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -in @("127.0.0.1","0.0.0.0") } | ' +
        'Select-Object -ExpandProperty OwningProcess -Unique) | ConvertTo-Json -Compress')
    result = runner(['powershell.exe', '-NoProfile', '-Command', script],
        capture_output=True, text=True, timeout=20,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    if result.returncode:
        raise RuntimeError('NEWS_CDP_OWNER_INSPECTION_FAILED')
    try:
        raw = json.loads(result.stdout.strip()) if result.stdout.strip() else []
    except (ValueError, TypeError):
        raise RuntimeError('NEWS_CDP_OWNER_INSPECTION_FAILED') from None
    values = raw if isinstance(raw, list) else [raw]
    if not all(type(pid) is int and pid > 0 for pid in values):
        raise RuntimeError('NEWS_CDP_OWNER_INSPECTION_FAILED')
    return set(values)


def verify_endpoint_owned(port, profile, *, find_pids, listeners=listener_process_ids):
    """A free-port observation alone is not authority to attach or close CDP."""
    own = set(find_pids(profile))
    listening = set(listeners(port))
    if not own or not listening or not listening <= own:
        raise RuntimeError('NEWS_CDP_ENDPOINT_NOT_OWNED')
    return True


def confirm_user_turn(page, *, event_id, revision, command_id, heartbeat,
                      timeout=90, clock=time.monotonic, sleep=time.sleep,
                      pages=None, on_match=None, on_observation=None):
    """Find the exact sent turn among owned pages; never click or send here."""
    started = last_heartbeat = clock()
    while clock() - started < timeout:
        if clock() - last_heartbeat >= 45:
            heartbeat()
            last_heartbeat = clock()
        candidates = [page] + (list(pages()) if pages else [])
        observed, matches, visited = [], {}, set()
        for candidate in candidates:
            if id(candidate) in visited:
                continue
            visited.add(id(candidate))
            try:
                url = candidate.url.split('?', 1)[0].split('#', 1)[0]
                users, answers = read_news_turns(candidate)
                identity = fresh_turn(users, event_id, revision, command_id)
                observed.append({'url': url, 'user_turn_count': len(users),
                                 'assistant_turn_count': len(answers), 'exact_identity': identity})
                if identity and CHAT.fullmatch(url):
                    matches[url] = candidate
            except Exception:
                observed.append({'inspection_failed': True})
        if on_observation:
            on_observation({'targets': observed[-12:]})
        if len(matches) > 1:
            raise RuntimeError('NEWS_MULTIPLE_MATCHING_CHATS_NO_RESEND')
        if matches:
            url, target = next(iter(matches.items()))
            if on_match:
                on_match(target)
            return url
        sleep(2)
    raise RuntimeError('NEWS_SUBMISSION_UNCONFIRMED_NO_RESEND')


def capture_reply(page, *, event_id, revision, command_id, heartbeat,
                  timeout=300, clock=time.monotonic, sleep=time.sleep):
    started = clock()
    last_heartbeat = started
    previous = ''
    previous_idle = False
    stable_since = started
    while clock() - started < timeout:
        now = clock()
        if now - last_heartbeat >= 45:
            heartbeat()
            last_heartbeat = clock()
        users, answers = read_news_turns(page)
        if fresh_turn(users, event_id, revision, command_id):
            answer = answers[-1].strip() if answers else ''
            idle = page.locator(STOP).count() == 0
            if answer != previous or not idle or not previous_idle:
                previous, stable_since = answer, now
            elif now - stable_since >= 6 and CHAT.fullmatch(page.url.split('?', 1)[0]):
                if re.match(r'^\s*TTN2_EDITORIAL_BLOCKED\b', answer):
                    raise RuntimeError('NEWS_EDITORIAL_BLOCKED_NO_RESEND')
                if 'TTN2_EDITORIAL_BEGIN' in answer and 'TTN2_EDITORIAL_END' in answer:
                    return answer, page.url.split('?', 1)[0]
            previous_idle = idle
        else:
            previous, previous_idle, stable_since = '', False, now
        sleep(2)
    raise RuntimeError('NEWS_CAPTURE_TIMEOUT_NO_RESEND')


class ChromeJob:
    def __init__(self, *, chrome, seed, profile, timeout=300):
        self.chrome, self.seed, self.profile = map(Path, (chrome, seed, profile))
        self.timeout = timeout
        self.process = self.browser = self.pw = self.hider = self.page = None
        self.composer = None
        self.find = common('chrome_profile_process_v2').exact_chrome_profile_pids
        self.cleanup_verified = False
        self.sent = False
        self.port = None
        self.profile_owned = False
        self.startup_diagnostic = None
        self.chrome_log = None
        self.recovery_diagnostic = None

    def open(self):
        if os.name != 'nt' or not self.chrome.is_file():
            raise RuntimeError('NEWS_WINDOWS_CHROME_REQUIRED')
        clone_job_profile(self.seed, self.profile, find_pids=self.find)
        self.profile_owned = True
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.port = port
        args = common('chrome_command_v2').command(self.chrome, self.profile, port,
                                                   headless=False, hidden=True)
        visibility = common('chrome_visibility_v2')
        self.profile.parent.mkdir(parents=True, exist_ok=True)
        self.chrome_log = (self.profile.parent / 'chrome.stderr.log').open('ab')
        self.process = subprocess.Popen(args, stdout=subprocess.DEVNULL,
            stderr=self.chrome_log, startupinfo=visibility.startupinfo_hidden(),
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        self.hider = visibility.V2WindowHider(lambda: self.find(self.profile),
                                             primary_pid=self.process.pid).start()
        endpoint = 'http://127.0.0.1:' + str(port)
        def probe():
            try:
                with urlopen(endpoint + '/json/version', timeout=2) as response:
                    json.load(response)
                return True
            except Exception:
                return False
        # A short-lived Windows launcher can hand Chrome to another process.
        # Reuse the proven trends startup boundary rather than treating poll()
        # alone as browser failure. CDP ownership is still checked below.
        startup = common('chrome_startup_v2')
        try:
            self.startup_diagnostic = startup.wait_for_cdp(self.process, probe,
                lambda: self.find(self.profile), attempts=45, delay=time.sleep)
        except startup.ChromeStartupError as exc:
            self.startup_diagnostic = {'launcher_code': self.process.poll(), 'ready': False,
                                       'reason': str(exc)}
            raise RuntimeError('NEWS_CHROME_STARTUP_UNAVAILABLE') from None
        verify_endpoint_owned(port, self.profile, find_pids=self.find)
        from playwright.sync_api import sync_playwright
        self.pw = sync_playwright().start()
        self.browser = self.pw.chromium.connect_over_cdp(endpoint)
        # Always a new page at home, never a restored /c/ conversation.
        self.page = self.browser.contexts[0].new_page()
        self.page.goto('https://chatgpt.com/', wait_until='domcontentloaded', timeout=60000)
        until = time.monotonic() + 90
        while time.monotonic() < until:
            if self.hider.last_error:
                raise RuntimeError('NEWS_CHROME_HIDE_FAILED')
            for selector in COMPOSERS:
                candidate = self.page.locator(selector).first
                if candidate.count() and candidate.is_visible() and candidate.is_enabled():
                    self.composer = candidate
                    break
            if self.composer is not None:
                break
            time.sleep(2)
        if (self.composer is None or self.page.url.split('?', 1)[0].rstrip('/') != 'https://chatgpt.com'
            or self.page.locator('[data-message-author-role="user"]').count()):
            raise RuntimeError('NEWS_CHATGPT_AUTH_OR_FRESH_CHAT_REQUIRED')
        if not authenticated_session(self.page):
            raise RuntimeError('NEWS_CHATGPT_AUTHENTICATED_ACCOUNT_REQUIRED')
        self.hider.ensure_hidden()

    def send_once(self, prompt):
        if self.sent or self.composer is None:
            raise RuntimeError('NEWS_SEND_NOT_AUTHORIZED')
        self.sent = True  # Enter is never retried even if the transport raises.
        self.composer.fill(prompt)
        self.composer.press('Enter')

    def capture(self, event_id, revision, command_id, heartbeat):
        return capture_reply(self.page, event_id=event_id, revision=revision,
                             command_id=command_id, heartbeat=heartbeat, timeout=self.timeout)

    def confirm_submission(self, event_id, revision, command_id, heartbeat=lambda: None):
        def select(target):
            self.page = target
        def observe(diagnostic):
            # Private local journal only: never include chat URLs in GitHub errors.
            self.recovery_diagnostic = diagnostic
        return confirm_user_turn(self.page, event_id=event_id, revision=revision,
            command_id=command_id, heartbeat=heartbeat,
            pages=lambda: [p for context in self.browser.contexts for p in context.pages],
            on_match=select, on_observation=observe)

    def close(self):
        # Layer failures must never skip the exact-profile process cleanup.
        # In particular do not send Browser.close to a replacement endpoint.
        failures = []
        owned_endpoint = False
        try:
            if self.browser and self.port is not None:
                try:
                    owned_endpoint = verify_endpoint_owned(self.port, self.profile, find_pids=self.find)
                except Exception:
                    owned_endpoint = False
                if owned_endpoint:
                    try:
                        self.browser.new_browser_cdp_session().send('Browser.close')
                    except Exception:
                        pass  # exact-profile taskkill remains the fallback
        finally:
            try:
                if self.hider:
                    self.hider.stop()
            except Exception:
                failures.append('hider')
            try:
                if self.browser and owned_endpoint:
                    self.browser.close()
            except Exception:
                pass
            try:
                if self.pw:
                    self.pw.stop()
            except Exception:
                failures.append('playwright')
            try:
                if self.process:
                    try:
                        self.process.wait(timeout=7)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                    except Exception:
                        failures.append('process_wait')
            finally:
                if self.process or self.profile_owned:
                    try:
                        cleanup = common('chrome_cleanup_v2').cleanup_v2_profile(lambda: self.find(self.profile))
                        self.cleanup_verified = cleanup['closed'] is True
                    except Exception:
                        self.cleanup_verified = False
                else:
                    # open() rejected before acquiring any profile/process.
                    self.cleanup_verified = True
        if not self.cleanup_verified:
            if getattr(self, 'chrome_log', None): self.chrome_log.close()
            raise RuntimeError('NEWS_OWN_CHROME_CLEANUP_UNVERIFIED')
        if getattr(self, 'chrome_log', None): self.chrome_log.close()
        # Never remove a pre-existing profile when open() rejected its reuse.
        if self.profile_owned and self.profile.exists():
            try:
                shutil.rmtree(self.profile)
            except Exception:
                raise RuntimeError('NEWS_OWN_PROFILE_CLEANUP_UNVERIFIED') from None
        if failures:
            raise RuntimeError('NEWS_BROWSER_RESOURCE_CLOSE_FAILED')
