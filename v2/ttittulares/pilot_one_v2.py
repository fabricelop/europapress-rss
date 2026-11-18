"""One supervised, never-replayed real editorial job before enabling News V2.

Windows only. The operator must first disable editorial.enabled; images and
Trends are unrelated. Uses the same eight-minute watchdog as the daemon.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

from .editorial_browser_v2 import common, write_private
from .editorial_consumer_v2 import github_token, settings
from .news_workflow_v2 import NewsService, NewsStore
from .session_watchdog_v2 import (
    OwnedSessionWatchdog, SESSION_LIMIT_SECONDS, active_news_worker_ids, enough_space,
)


def emit(**data):
    print(json.dumps(data, ensure_ascii=False, sort_keys=True), flush=True)


def safe_first_job(job):
    if not isinstance(job, dict):
        return False
    attempts = job.get('attempts') or {}
    return (job.get('status') == 'pending'
            and type(job.get('revision')) is int and job['revision'] >= 1
            and not any(job.get(key) for key in
                        ('lease', 'send_intent', 'session', 'capture', 'result', 'problem'))
            and attempts.get('claim_count', 0) == 0
            and attempts.get('submission_count', 0) == 0
            and not attempts.get('history')
            and bool(re.fullmatch(r'[A-Za-z0-9_-]{8,120}', str(job.get('job_id', '')))))


def main():
    if os.name != 'nt' or not os.environ.get('LOCALAPPDATA'):
        emit(status='blocked', reason='WINDOWS_SESSION_REQUIRED')
        return 2
    root = Path(os.environ['LOCALAPPDATA']) / 'TTActualidadNoticiasV2'
    try:
        config = settings(root)
        if not config['min_requested_at'] or not enough_space(root):
            emit(status='blocked', reason='CUTOFF_OR_DISK_SPACE_NOT_READY')
            return 2
        pointer = Path((root / 'active-code.txt').read_text(encoding='utf-8-sig').strip()).resolve()
        if (pointer != Path(__file__).resolve().parents[2] or
                pointer.parent != (root / 'releases').resolve()):
            emit(status='blocked', reason='PINNED_EDITORIAL_RELEASE_REQUIRED')
            return 2
        if (root / 'editorial.enabled').read_text(encoding='utf-8-sig').strip() != 'TTN2_EDITORIAL_ENABLED=NO':
            emit(status='blocked', reason='DAEMON_MUST_STAY_DISABLED')
            return 2
        service = NewsService(NewsStore(github_token()),
                              min_requested_at=config['min_requested_at'])
        with common('process_lock_v2').exclusive_v2_lock(root / 'consumer.lock'):
            if active_news_worker_ids(False):
                emit(status='blocked', reason='EDITORIAL_WORKER_ALREADY_RUNNING')
                return 2
            plan = service.preview()
            if plan.get('active_count', 0) != 0:
                emit(status='blocked', reason='REMOTE_JOB_ALREADY_ACTIVE')
                return 2
            jobs = plan.get('next_jobs') or []
            if not jobs or not plan.get('pending_count'):
                emit(status='idle', reason='NO_PENDING_NEWS', published=False)
                return 0
            job = jobs[0]
            if not safe_first_job(job):
                emit(status='blocked', reason='NEXT_PENDING_JOB_IS_NOT_FRESH',
                     job_id=job.get('job_id'))
                return 2
            run_id = uuid.uuid4().hex
            logdir = root / 'logs'
            logdir.mkdir(parents=True, exist_ok=True)
            logfile = logdir / ('pilot-v1-style-' + run_id + '.log')
            with logfile.open('w', encoding='utf8') as out:
                process = subprocess.Popen(
                    [sys.executable, '-m', 'v2.ttittulares.editorial_consumer_v2',
                     '--root', str(root), '--run-one', '--run-id', run_id],
                    cwd=str(pointer), stdout=out, stderr=subprocess.STDOUT,
                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                watcher = OwnedSessionWatchdog(root, run_id, process).start()
                process.wait()
                observation = watcher.finalize()
            if observation['timed_out']:
                saved = False
                try:
                    path = root / 'journals' / (run_id + '.json')
                    journal = json.loads(path.read_text(encoding='utf8'))
                    journal['session_deadline_exceeded'] = True
                    journal['supervisor_cleanup_verified'] = observation['cleanup_verified']
                    write_private(path, journal)
                    result = service.fail(journal['job_id'], journal['worker_id'],
                                          journal['lease_token'], code='NEWS_SESSION_DEADLINE_EXCEEDED',
                                          safe_preflight=(not journal['intent_durable']
                                                          and observation['cleanup_verified']))
                    saved = result.get('verified') is True
                except (OSError, ValueError, KeyError, RuntimeError):
                    pass
                emit(status='incident', reason='SESSION_DEADLINE',
                     deadline_seconds=SESSION_LIMIT_SECONDS,
                     supervisor_cleanup_verified=observation['cleanup_verified'],
                     failure_persisted=saved, published=False, log_file=str(logfile))
                return 1
            report = None
            for line in reversed(logfile.read_text(encoding='utf8', errors='replace').splitlines()):
                try:
                    candidate = json.loads(line)
                except ValueError:
                    continue
                if isinstance(candidate, dict) and 'status' in candidate:
                    report = candidate
                    break
            if not report:
                emit(status='incident', reason='CHILD_REPORT_MISSING',
                     supervisor_cleanup_verified=observation['cleanup_verified'],
                     log_file=str(logfile), published=False)
                return 1
            report.pop('chat_url', None)
            report.update(pilot='one_v1_style_news', expected_job_id=job['job_id'],
                          supervisor_cleanup_verified=observation['cleanup_verified'],
                          worker_started=1, images_unchanged=True, published=False,
                          log_file=str(logfile))
            emit(**report)
            return 0 if (report.get('status') == 'ready'
                         and report.get('cleanup_verified') is True
                         and observation['cleanup_verified']) else 1
    except Exception as exc:
        emit(status='blocked', reason=type(exc).__name__.upper(), published=False)
        return 2


if __name__ == '__main__':
    sys.exit(main())
