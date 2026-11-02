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
        result = guard.evaluate('ttendencias', now, {}, command=command,
                                run=guard.known_run('ttendencias'), rows=rows)
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
