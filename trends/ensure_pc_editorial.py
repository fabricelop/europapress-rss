#!/usr/bin/env python3
"""Wake the existing text editor after either radar producer persists main.

Use the compact queue, without Telegram delivery state. Existing run/command
guards provide cooldown and concurrent dispatch deduplication. Never explain,
generate an image, or change an editorial card here.
"""
import base64
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from shared import tt_editorial_run_guard as guard


def fresh_queue_first_handoff_allowed(rows, command, run, now):
    """Wake a newly persisted backlog immediately, without awaiting a delayed cron.

    Only the FIRST handoff is eligible here. Existing commands, active editor
    runs and all subsequent retries stay under the shared durable watchdog.
    """
    starts = [guard.moment(row.get('start')) for row in rows]
    starts = [item for item in starts if item is not None]
    if not starts:
        return False
    oldest = min(starts)
    sent = guard.moment((command or {}).get('requested_at'))
    if sent and sent >= oldest:
        return False
    run = run or {}
    run_status = str(run.get('status') or '').upper()
    run_updated = guard.moment(run.get('updated_at'))
    if (run_status in {'RUNNING', 'IN_PROGRESS', 'PROCESSING'}
            and run_updated and now - run_updated < guard.ACTIVE_TTL):
        return False
    return True


def ensure(now=None):
    now = now or datetime.now(timezone.utc)
    queue = json.loads((ROOT / 'trends/editorial-queue.json').read_text(encoding='utf8'))
    rows = [{'id': str(x['id']), 'start': x.get('requested_at'),
             'title': x.get('name') or x['id']} for x in queue.get('items', [])
            if x.get('id') and x.get('status') in {'preparing', 'update'}]
    if not rows:
        result = {'status': 'no_work', 'pending_count': 0, 'should_dispatch': False}
    else:
        cfg = guard.CONFIG['ttendencias']
        current = guard.api('contents/' + cfg['control'], branch=cfg['branch'])
        command = json.loads(base64.b64decode(current['content']))
        current_run = guard.known_run('ttendencias')
        result = guard.evaluate('ttendencias', now, {}, command=command,
                                run=current_run, rows=rows)
        # GitHub's GITHUB_TOKEN push does not wake downstream push workflows,
        # and schedule ticks can be delayed. The producer must request its
        # FIRST missing editorial handoff as soon as the backlog is durable.
        # A recent command or a live run still blocks it; further retries are
        # exclusively the persistent shared watchdog's responsibility.
        if (result['status'] == 'within_start_window'
                and fresh_queue_first_handoff_allowed(rows, command, current_run, now)):
            result.update(status='fresh_queue_initial_handoff', should_dispatch=True)
        # This producer only supplies the missing initial handoff. Recovery of
        # an already dispatched backlog belongs to the durable watchdog, with
        # its persisted three-attempt budget, never an endless radar replay.
        starts = [guard.moment(x['start']) for x in rows]
        starts = [x for x in starts if x is not None]
        sent = guard.moment(command.get('requested_at'))
        if result['should_dispatch'] and starts and sent and sent >= min(starts):
            result.update(status='awaiting_watchdog_recovery', should_dispatch=False)
        if result['should_dispatch']:
            result['dispatch'] = guard.request('ttendencias', now, result)
            result['status'] = ('dispatch_requested_awaiting_run' if result['dispatch']['requested']
                                else 'remote_command_active')
    print('TT_TRENDS_ENSURE_EDITORIAL ' + json.dumps(result, ensure_ascii=False))
    return result


if __name__ == '__main__':
    ensure()
