"""Three independent news workers. The CAS service owns global capacity/FIFO.

Run on the authenticated Windows account. --check is read-only, --run-one
handles one job, --daemon keeps three slots while the local flag is enabled.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request

from .editorial_browser_v2 import ChromeJob, common, write_private
from .news_workflow_v2 import NewsStore, allowed as news_allowed
from .radar_store_v2 import REPOSITORY, StoreError, UncertainCommit, _oid


# Shared with Tendencias, but not imported by Images or the news radar.
_GH_SHARED = Path(os.environ.get('LOCALAPPDATA', '.')) / 'TTActualidadV2'
_GH_BUDGET = _GH_SHARED / 'github-api-budget.json'
_GH_COOLDOWN = _GH_SHARED / 'github-api-cooldown.json'
_GH_RESERVE = 800


def _header(headers, name):
    return next((str(value) for key, value in headers.items()
                 if key.lower() == name.lower()), '')


def _budget_low(*, clock=time.time):
    try:
        budget = json.loads(_GH_BUDGET.read_text(encoding='utf-8'))
        if float(budget['reset']) > clock() and int(budget['remaining']) <= _GH_RESERVE:
            return True
    except (OSError, ValueError, TypeError, KeyError):
        pass
    try:
        paused = json.loads(_GH_COOLDOWN.read_text(encoding='utf-8'))
        return float(paused['until']) > clock()
    except (OSError, ValueError, TypeError, KeyError):
        return False


def _cooldown_remaining(*, clock=time.time):
    try:
        return max(0, int(float(json.loads(_GH_COOLDOWN.read_text(
            encoding='utf-8'))['until']) - clock()))
    except (OSError, ValueError, TypeError, KeyError):
        return 0


def _atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(json.dumps(value) + '\n', encoding='utf-8')
    temporary.replace(path)


def _note_budget(headers, *, clock=time.time):
    remaining = _header(headers, 'x-ratelimit-remaining')
    reset = _header(headers, 'x-ratelimit-reset')
    if not remaining.isdigit() or not reset.isdigit() or int(remaining) > _GH_RESERVE:
        return
    count, deadline = int(remaining), int(reset)
    try:
        previous = json.loads(_GH_BUDGET.read_text(encoding='utf-8'))
        if int(previous['reset']) == deadline and deadline > clock():
            count = min(count, int(previous['remaining']))
    except (OSError, ValueError, TypeError, KeyError):
        pass
    try:
        _atomic_json(_GH_BUDGET, {'remaining': count, 'reset': deadline})
    except OSError:
        pass  # Monitoring cannot corrupt or interrupt an editorial commit.


def _remember_limit(exc, *, clock=time.time):
    headers = exc.headers or {}
    _note_budget(headers, clock=clock)
    remaining = _header(headers, 'x-ratelimit-remaining')
    reset = _header(headers, 'x-ratelimit-reset')
    retry = _header(headers, 'retry-after')
    try:
        message = json.loads(exc.read(1024).decode('utf-8')).get('message', '')
    except (ValueError, AttributeError, UnicodeError, OSError):
        message = ''
    if not (remaining == '0' or retry or 'rate limit' in str(message).lower()):
        return False
    seconds = max(75, int(retry) if retry.isdigit() else 0)
    if remaining == '0' and reset.isdigit():
        seconds = max(seconds, int(int(reset) - clock() + 3))
    until = clock() + min(3600, seconds)
    try:
        previous = json.loads(_GH_COOLDOWN.read_text(encoding='utf-8'))
        until = max(until, float(previous['until']))
    except (OSError, ValueError, TypeError, KeyError):
        pass
    try:
        _atomic_json(_GH_COOLDOWN, {'until': until})
    except OSError:
        pass
    return True


class EconomicalEditorialStore(NewsStore):
    """Only editorial jobs use these economical, CAS-safe GitHub reads."""

    def __init__(self, token, **kwargs):
        self._branch_response = None
        self._branch_etag = None
        self._snapshot_head = None
        self._snapshot_docs = None
        super().__init__(token, **kwargs)

    def _http_json(self, method, path, payload=None):
        if not (path.startswith('/repos/' + REPOSITORY + '/') or path == '/graphql'):
            raise StoreError('GITHUB_ENDPOINT_OUTSIDE_SCOPE')
        if _cooldown_remaining():
            raise StoreError('GITHUB_RATE_LIMIT_PAUSED')
        body = json.dumps(payload).encode('utf-8') if payload is not None else None
        headers = {'Authorization': 'Bearer ' + self._token,
                   'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2022-11-28',
                   'User-Agent': 'TTNoticiasV2-Editorial',
                   'Content-Type': 'application/json'}
        branch = method == 'GET' and path.startswith('/repos/' + REPOSITORY + '/branches/')
        if branch and self._branch_etag:
            headers['If-None-Match'] = self._branch_etag
        request = Request('https://api.github.com' + path, data=body,
                          method=method, headers=headers)
        try:
            with self._opener.open(request, timeout=60) as response:
                raw = response.read(32_000_001)
                _note_budget(response.headers)
                if branch:
                    self._branch_etag = response.headers.get('ETag')
            if len(raw) > 32_000_000:
                raise StoreError('GITHUB_RESPONSE_TOO_LARGE')
            result = json.loads(raw)
            if branch:
                self._branch_response = copy.deepcopy(result)
            return result
        except HTTPError as exc:
            if exc.code == 304 and branch and self._branch_response is not None:
                _note_budget(exc.headers or {})
                return copy.deepcopy(self._branch_response)
            if method == 'POST' and exc.code >= 500:
                raise UncertainCommit('GITHUB_COMMIT_RESPONSE_UNCERTAIN') from None
            if exc.code in (403, 429) and _remember_limit(exc):
                raise StoreError('GITHUB_RATE_LIMIT_PAUSED') from None
            raise StoreError('GITHUB_HTTP_' + str(exc.code)) from None
        except (URLError, TimeoutError, ConnectionError, OSError):
            if method == 'POST':
                raise UncertainCommit('GITHUB_COMMIT_RESPONSE_UNCERTAIN') from None
            raise StoreError('GITHUB_READ_FAILED') from None
        except (ValueError, UnicodeError):
            if method == 'POST':
                raise UncertainCommit('GITHUB_COMMIT_RESPONSE_UNCERTAIN') from None
            raise StoreError('GITHUB_JSON_INVALID') from None

    def read_editorial_snapshot(self):
        head = self.head()
        if head == self._snapshot_head and self._snapshot_docs is not None:
            return head, copy.deepcopy(self._snapshot_docs)
        inventory = self.inventory(head)
        docs = self.read_documents(head, [path for path, entry in inventory.items()
            if entry.get('type') != 'tree' and news_allowed(path)])
        self._snapshot_head, self._snapshot_docs = head, copy.deepcopy(docs)
        return head, docs


def github_token():
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if token and token.strip():
        return token.strip()
    try:
        run = subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True,
                             check=True, timeout=15,
                             creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError('NEWS_GITHUB_AUTH_REQUIRED') from None
    if not run.stdout.strip():
        raise RuntimeError('NEWS_GITHUB_AUTH_REQUIRED')
    return run.stdout.strip()


def error_code(exc):
    message = str(exc)
    return message if re.fullmatch(r'[A-Z][A-Z0-9_]{2,100}', message) else type(exc).__name__.upper()


# Only positive evidence of a missing authenticated account or dedicated seed
# may pause the entire pipeline. A fresh-tab/composer failure is preflight
# trouble on ONE disposable profile, not proof that the login has expired.
FATAL_AUTH_CODES = frozenset({
    'NEWS_CHATGPT_AUTHENTICATED_ACCOUNT_REQUIRED',
    'NEWS_DEDICATED_AUTH_SEED_REQUIRED',
    'NEWS_AUTH_SEED_MISSING',
})


def settings(root):
    root = Path(root).resolve()
    config = json.loads((root / 'settings.json').read_text(encoding='utf-8-sig'))
    if config.get('project') != 'ttittulares-v2' or config.get('workers') != 3:
        raise RuntimeError('NEWS_SETTINGS_INVALID')
    seed = Path(config['seed_profile']).resolve()
    if seed != root / 'AuthSeed':
        raise RuntimeError('NEWS_DEDICATED_AUTH_SEED_REQUIRED')
    chrome = Path(config['chrome'])
    if not seed.is_dir() or not chrome.is_file():
        raise RuntimeError('NEWS_CHROME_OR_AUTH_SEED_MISSING')
    boundary = root / 'editorial-from.txt'
    # Set once by the scoped launcher; leave pre-existing installations
    # unchanged until an operator explicitly enables this new date boundary.
    return {'root': root, 'seed': seed, 'chrome': chrome,
            'min_requested_at': boundary.read_text(encoding='utf-8-sig').strip() if boundary.exists() else None}


def run_one(service, config, *, browser_factory=ChromeJob, parse=None, build=None,
            run_id=None):
    from .editorial_contract_v2 import build_prompt, parse_record, ContractError
    build, parse = build or build_prompt, parse or parse_record
    run_id = run_id or uuid.uuid4().hex
    worker_id = 'news-' + run_id
    token = secrets.token_hex(32)
    try:
        claim = service.claim(worker_id, token)
    except Exception as exc:
        # A network failure before a claim can be durably acknowledged must
        # never be mistaken for a failed ChatGPT generation. In particular,
        # no browser, prompt or send intent has been created here.
        return {'status': 'incident', 'published': False,
                'error_code': error_code(exc), 'error_type': type(exc).__name__,
                'pre_chat_failure': True, 'cleanup_verified': False}
    if not claim or not claim.get('job'):
        return {'status': 'idle', 'published': False}
    job, event = claim['job'], claim['event']
    job_id, event_id, revision = job['job_id'], job['event_id'], job['revision']
    command_id = 'news-' + uuid.uuid4().hex
    journal_path = config['root'] / 'journals' / (run_id + '.json')
    profile = config['root'] / 'sessions' / run_id / 'Profile'
    journal = {'run_id': run_id, 'worker_id': worker_id, 'lease_token': token,
               'command_id': command_id, 'event_id': event_id, 'revision': revision,
               'job_id': job_id, 'sent': False, 'intent_durable': False,
               'captured': False, 'cleanup_verified': False, 'published': False,
               'submission_confirmed': False, 'capture_persisted': False}
    browser = None
    failure = None
    record = None
    try:
        write_private(journal_path, journal)
        browser = browser_factory(chrome=config['chrome'], seed=config['seed'], profile=profile)
        browser.open()
        prompt = build(event, job, command_id)
        if claim.get('hints'):
            prompt += '\nINSTRUCCIONES DE REELABORACIÓN DEL EDITOR:\n' + claim['hints']
        prompt_hash = hashlib.sha256(prompt.encode('utf-8')).hexdigest()
        journal['prompt_sha256'] = prompt_hash
        write_private(journal_path, journal)
        session = {'session_id': run_id, 'private_journal_id': run_id,
                   'conversation_url_sha256': hashlib.sha256(b'https://chatgpt.com/').hexdigest()}
        # JIT revalidation + durable intent before the sole Enter. An uncertain
        # commit/response NEVER grants permission to send by assumption.
        authorization = service.prepare_send(job_id, worker_id, token,
            prompt_sha256=prompt_hash, command_id=command_id, session=session)
        journal['intent_durable'] = True
        write_private(journal_path, journal)
        if authorization.get('send_authorized') is not True:
            raise RuntimeError('NEWS_SEND_REPLAY_OR_UNCERTAIN_NO_RESEND')
        browser.send_once(prompt)
        journal['sent'] = True
        write_private(journal_path, journal)
        chat_url = browser.confirm_submission(event_id, revision, command_id,
            heartbeat=lambda: service.heartbeat(job_id, worker_id, token))
        journal['chat_url'] = chat_url
        write_private(journal_path, journal)
        submitted = service.submitted(job_id, worker_id, token,
                          conversation_url_sha256=hashlib.sha256(chat_url.encode()).hexdigest())
        journal['submission_confirmed'] = isinstance(submitted, dict) and submitted.get('verified') is True
        write_private(journal_path, journal)
        answer, chat_url = browser.capture(event_id, revision, command_id,
            lambda: service.heartbeat(job_id, worker_id, token))
        # This is private local recovery material, never a public ChatGPT URL.
        journal.update(answer=answer, chat_url=chat_url, captured=True)
        write_private(journal_path, journal)
        captured = service.captured(job_id, worker_id, token,
            answer_sha256=hashlib.sha256(answer.encode('utf-8')).hexdigest(),
            local_journal_id=run_id)
        journal['capture_persisted'] = isinstance(captured, dict) and captured.get('verified') is True
        write_private(journal_path, journal)
        from datetime import datetime, timezone
        record = parse(answer, event, job, command_id, datetime.now(timezone.utc))
    except Exception as exc:
        failure = exc
        # Codes only in stdout; never echo request headers, ChatGPT content,
        # browser URLs or credentials from a generic exception.
        journal['error_type'] = type(exc).__name__
        journal['error_code'] = error_code(exc)
        if browser and isinstance(getattr(browser, 'recovery_diagnostic', None), dict):
            journal['private_recovery_diagnostic'] = browser.recovery_diagnostic
        if browser and isinstance(getattr(browser, 'capture_diagnostic', None), dict):
            journal['private_capture_diagnostic'] = browser.capture_diagnostic
        if browser and isinstance(getattr(browser, 'startup_diagnostic', None), dict):
            journal['startup_diagnostic'] = browser.startup_diagnostic
        if journal['error_code'] in FATAL_AUTH_CODES:
            # A missing login affects the whole consumer, not the facts of the
            # next 100 stories. Stop new claims while other slots finish safely.
            (config['root'] / 'editorial.enabled').write_text('TTN2_EDITORIAL_ENABLED=NO', encoding='utf-8')
        write_private(journal_path, journal)
    finally:
        if browser:
            try:
                # A durable journal (not a reusable Chrome profile) is the
                # evidence for an uncertain send.  Never resend blindly, but
                # discard the one-job profile after verified Chrome cleanup.
                browser.close()
                journal['cleanup_verified'] = browser.cleanup_verified
            except Exception as exc:
                journal['cleanup_error_type'] = type(exc).__name__
                failure = failure or exc
        write_private(journal_path, journal)
    # A session that is not proven closed may still be holding an owned Chrome.
    # Never count it as a safely retryable pre-send failure, even if no Enter
    # was observed. The exact-profile supervisor handles recovery separately.
    if not journal['cleanup_verified'] and failure is None:
        failure = RuntimeError('NEWS_OWN_CHROME_CLEANUP_UNVERIFIED')
    if failure is not None:
        failure_persisted = False
        try:
            failed = service.fail(job_id, worker_id, token, code=error_code(failure),
                         safe_preflight=(not journal['intent_durable'] and
                                         journal['cleanup_verified']))
            failure_persisted = isinstance(failed, dict) and failed.get('verified') is True
        except Exception:
            # Local journal + durable intent/lease are still the recovery truth.
            journal['failure_persistence_unverified'] = True
            write_private(journal_path, journal)
        # A verified rejected editorial answer is an isolated content incident.
        # It proves the transport/capture/cleanup cycle, never a publishable READY.
        quarantined = (isinstance(failure, ContractError)
            and journal['captured'] is True and journal['submission_confirmed'] is True
            and journal['capture_persisted'] is True and journal['cleanup_verified'] is True
            and failure_persisted)
        return {'status': 'quarantined' if quarantined else 'incident',
                'job_id': job_id, 'published': False,
                'submission_confirmed': journal['submission_confirmed'],
                'capture_complete': journal['captured'], 'capture_persisted': journal['capture_persisted'],
                'failure_persisted': failure_persisted,
                'error_type': type(failure).__name__, 'error_code': error_code(failure),
                'private_recovery_evidence_saved': bool(journal.get('private_recovery_diagnostic')),
                **({'startup_diagnostic': journal['startup_diagnostic']} if journal.get('startup_diagnostic') else {}),
                'cleanup_verified': journal['cleanup_verified']}
    # Text may only become ready after our own browser has closed. complete()
    # verifies the immutable record before updating event/index/job to ready.
    if not record or not journal['cleanup_verified']:
        raise RuntimeError('NEWS_CAPTURE_OR_CLEANUP_NOT_VERIFIED')
    try:
        completed = service.complete(job_id, worker_id, token, record)
    except Exception as exc:
        # Captured text and its journal remain recoverable. Do not send again
        # or turn an unverified materialization into a success report.
        journal['completion_error_type'] = type(exc).__name__
        journal['ready_verified'] = False
        write_private(journal_path, journal)
        return {'status': 'incident', 'job_id': job_id, 'published': False,
                'error_type': type(exc).__name__, 'cleanup_verified': True,
                'capture_saved_locally': True}
    journal['ready_verified'] = completed.get('verified') is True
    journal['record_commit'] = completed.get('commit_sha')
    write_private(journal_path, journal)
    if not journal['ready_verified']:
        raise RuntimeError('NEWS_READY_READBACK_UNVERIFIED')
    return {'status': 'ready', 'job_id': job_id, 'commit_sha': completed.get('commit_sha'),
            'cleanup_verified': True, 'published': False}


def enabled(root):
    try:
        return (Path(root) / 'editorial.enabled').read_text(encoding='utf-8').strip() == 'TTN2_EDITORIAL_ENABLED=YES'
    except FileNotFoundError:
        return False


def preflight_once(config, *, browser_factory=ChromeJob):
    """Prove a fresh authenticated tab without claiming a job or sending."""
    browser = browser_factory(chrome=config['chrome'], seed=config['seed'],
        profile=config['root'] / 'sessions' / ('preflight-' + uuid.uuid4().hex) / 'Profile')
    failed = None
    stage = None
    try:
        browser.open()
    except Exception as exc:
        failed = error_code(exc)
        stage = getattr(browser, 'fresh_chat_diagnostic', None)
    try:
        browser.close()
    except Exception:
        return {'ok': False, 'error_code': 'NEWS_OWN_CHROME_CLEANUP_UNVERIFIED',
                'cleanup_verified': False, 'stage': stage}
    return {'ok': failed is None, 'error_code': failed,
            'cleanup_verified': True, 'stage': stage}


def daemon(service, config, *, poll=30):
    pool = {}
    watchers = {}
    from .session_watchdog_v2 import (OwnedSessionWatchdog, enough_space,
        reclaim_disposable_sessions, ORPHAN_SWEEP_INTERVAL_SECONDS)
    logs = config['root'] / 'logs'
    logs.mkdir(parents=True, exist_ok=True)
    next_sweep = 0
    preflight_verified = False
    next_preflight = 0
    preflight_failures = 0
    unsafe_preflight_cleanup = False
    preflight_code = None
    preflight_stage = None
    next_idle_preview = 0.0
    # The OS lock protects this PC; the GitHub CAS service protects all PCs.
    with common('process_lock_v2').exclusive_v2_lock(config['root'] / 'consumer.lock'):
        while enabled(config['root']) or pool:
            if time.monotonic() >= next_sweep:
                report = reclaim_disposable_sessions(config['root'])
                try:
                    write_private(config['root'] / 'editorial-reclaim-status.json', report)
                except OSError:
                    pass  # Disk diagnostics cannot interrupt editorial work.
                next_sweep = time.monotonic() + ORPHAN_SWEEP_INTERVAL_SECONDS
            for slot, child in list(pool.items()):
                if child.poll() is not None:
                    watch = watchers.pop(slot)
                    outcome = watch.finalize()
                    if outcome['timed_out']:
                        path = config['root'] / 'journals' / (watch.run_id + '.json')
                        try:
                            journal = json.loads(path.read_text(encoding='utf-8'))
                            journal['session_deadline_exceeded'] = True
                            journal['supervisor_cleanup_verified'] = outcome['cleanup_verified']
                            write_private(path, journal)
                            service.fail(journal['job_id'], journal['worker_id'],
                                journal['lease_token'], code='NEWS_SESSION_DEADLINE_EXCEEDED',
                                safe_preflight=(not journal['intent_durable'] and
                                                outcome['cleanup_verified']))
                        except (OSError, ValueError, KeyError, RuntimeError):
                            # The original lease and journal remain fenced. No
                            # guessed resend is permitted on an uncertain send.
                            pass
                    del pool[slot]
            # All editorial consumers share the account's primary GitHub
            # allowance. Stop new claims before exhausting the portion needed
            # by jobs already in ChatGPT, including Tendencias jobs.
            if enabled(config['root']) and _budget_low():
                try:
                    write_private(config['root'] / 'editorial-daemon-health.json', {
                        'at': datetime.now(timezone.utc).isoformat(),
                        'state': 'WAIT_GITHUB_BUDGET', 'workers': len(pool),
                        'claims_authorized': False, 'error_code': 'GITHUB_BUDGET_RESERVED',
                    })
                except OSError:
                    pass
                time.sleep(poll)
                continue
            if enabled(config['root']) and not preflight_verified:
                now = time.monotonic()
                if unsafe_preflight_cleanup:
                    state = 'WAIT_BROWSER_CLEANUP'
                elif now < next_preflight:
                    state = 'WAIT_FRESH_CHAT_RETRY'
                else:
                    try:
                        write_private(config['root'] / 'editorial-daemon-health.json', {
                            'at': datetime.now(timezone.utc).isoformat(),
                            'state': 'CHECKING_FRESH_CHAT', 'workers': len(pool),
                            'claims_authorized': False, 'error_code': None,
                        })
                    except OSError:
                        pass
                    check = preflight_once(config)
                    if check['ok']:
                        preflight_verified = True
                        preflight_code = None
                        preflight_stage = 'FRESH_CHAT_VERIFIED'
                        state = 'FRESH_CHAT_VERIFIED'
                    else:
                        preflight_failures += 1
                        preflight_code = check['error_code']
                        preflight_stage = check.get('stage')
                        unsafe_preflight_cleanup = not check['cleanup_verified']
                        next_preflight = time.monotonic() + min(300, 30 * (2 ** min(preflight_failures-1, 4)))
                        state = 'WAIT_BROWSER_CLEANUP' if unsafe_preflight_cleanup else 'WAIT_FRESH_CHAT_RETRY'
                try:
                    write_private(config['root'] / 'editorial-daemon-health.json', {
                        'at': datetime.now(timezone.utc).isoformat(),
                        'state': state, 'workers': len(pool),
                        'claims_authorized': preflight_verified,
                        'preflight_failures': preflight_failures,
                        'error_code': preflight_code,
                        'fresh_chat_stage': preflight_stage,
                    })
                except OSError:
                    pass
                if not preflight_verified:
                    time.sleep(poll)
                    continue
            if enabled(config['root']):
                if len(pool) >= 3 or time.monotonic() < next_idle_preview:
                    # Active children perform their own CAS/heartbeats. The
                    # supervisor needs no repository snapshot while full.
                    time.sleep(poll)
                    continue
                from .news_workflow_v2 import sync_controls
                try:
                    sync_controls(service)
                    plan = service.preview()
                except Exception as exc:
                    # The old daemon exited on a single failed preview, leaving
                    # Pendientes full with zero active workers. Never silently
                    # claim without verified D1 controls or a current snapshot.
                    try:
                        write_private(config['root'] / 'editorial-daemon-health.json', {
                            'at': datetime.now(timezone.utc).isoformat(),
                            'state': 'WAIT_BACKEND', 'error_code': error_code(exc),
                            'workers': len(pool), 'claims_authorized': False,
                        })
                    except OSError:
                        pass
                    time.sleep(poll)
                    continue
                pending = plan.get('pending_count', 0)
                next_idle_preview = (time.monotonic() + 90
                                     if not pending and not plan.get('maintenance_needed')
                                     else 0.0)
                try:
                    write_private(config['root'] / 'editorial-daemon-health.json', {
                        'at': datetime.now(timezone.utc).isoformat(),
                        'state': 'RUNNING' if pending else 'WAIT_NO_ELIGIBLE_JOB',
                        'pending_eligible': pending, 'workers': len(pool),
                        'min_requested_at': plan.get('min_requested_at'),
                        'maintenance_needed': bool(plan.get('maintenance_needed')),
                        'error_code': None,
                    })
                except OSError:
                    pass
                if plan.get('maintenance_needed') and pending == 0:
                    pending = 1  # claim() safely releases/quarantines expired leases.
                for slot in range(3):
                    if pending <= 0:
                        break
                    if slot in pool:
                        continue
                    if not enough_space(config['root']):
                        # Do not claim work while a new profile copy could
                        # exhaust C:. Existing children still drain normally.
                        break
                    run_id = uuid.uuid4().hex
                    logfile = logs / ('worker-' + uuid.uuid4().hex + '.log')
                    with logfile.open('w', encoding='utf-8') as output:
                        pool[slot] = subprocess.Popen([sys.executable, '-m',
                            'v2.ttittulares.editorial_consumer_v2', '--root', str(config['root']),
                            '--run-one', '--run-id', run_id],
                            cwd=str(Path(__file__).resolve().parents[2]), stdout=output,
                            stderr=subprocess.STDOUT, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                    watchers[slot] = OwnedSessionWatchdog(config['root'], run_id, pool[slot]).start()
                    pending -= 1
            # An operator disabling the flag stops new claims. Already sent
            # jobs finish/capture/close; the parent never kills their browser.
            time.sleep(poll)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(os.environ.get('LOCALAPPDATA', '.')) / 'TTActualidadNoticiasV2')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--check', action='store_true')
    group.add_argument('--run-one', action='store_true')
    group.add_argument('--daemon', action='store_true')
    parser.add_argument('--run-id', help='Internal one-job UUID from the supervising daemon')
    args = parser.parse_args()
    from .news_workflow_v2 import NewsService
    config = settings(args.root)
    service = NewsService(EconomicalEditorialStore(github_token()),
                          min_requested_at=config['min_requested_at'])
    if args.check:
        print(json.dumps({'project': 'ttittulares-v2', 'preview': service.preview(),
                          'browser_opened': False, 'published': False}))
    elif args.daemon:
        # Keep the supervisor alive during a transient ChatGPT fresh-tab
        # failure. The daemon refuses all claims until the authenticated
        # disposable preflight has passed and its Chrome has been cleaned.
        daemon(service, config)
    else:
        if args.run_id and (not re.fullmatch(r'[a-f0-9]{32}', args.run_id) or not args.run_one):
            parser.error('--run-id only accepts a supervised run-one UUID')
        report = run_one(service, config, run_id=args.run_id)
        print(json.dumps(report))
        if report['status'] == 'incident':
            raise SystemExit(1)


if __name__ == '__main__':
    main()

