import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wakeup', ROOT / 'trends/ensure_pc_editorial.py')
wakeup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wakeup)


class RadarWakeupTests(unittest.TestCase):
    now = datetime(2026, 11, 2, 19, 0, tzinfo=timezone.utc)

    def check(self, rows, run=None, sent='2026-11-02T16:00:00Z'):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / 'trends').mkdir()
            (root / 'trends/editorial-queue.json').write_text(json.dumps({'items': rows}))
            command = {'command_id': 'previous', 'requested_at': sent}
            raw = {'content': base64.b64encode(json.dumps(command).encode()).decode()}
            with patch.object(wakeup, 'ROOT', root), patch.object(wakeup.guard, 'api', return_value=raw), patch.object(wakeup.guard, 'known_run', return_value=run or {}), patch.object(wakeup.guard, 'request', return_value={'requested': True}) as request:
                result = wakeup.ensure(self.now)
                return result, request.call_count

    def row(self, state='preparing'):
        return {'id': 'existing-card', 'status': state, 'requested_at': '2026-11-02T17:11:24Z'}

    def test_existing_backlog_from_other_producer_gets_initial_handoff(self):
        result, calls = self.check([self.row()])
        self.assertEqual(calls, 1)
        self.assertEqual(result['pending_ids'], ['existing-card'])

    def test_running_editor_is_preserved(self):
        result, calls = self.check([self.row()], {'status': 'RUNNING', 'updated_at': self.now.isoformat()})
        self.assertEqual(calls, 0)
        self.assertEqual(result['status'], 'editor_running_acknowledged')

    def test_recent_handoff_is_not_duplicated(self):
        result, calls = self.check([self.row()], sent='2026-11-02T18:58:00Z')
        self.assertEqual(calls, 0)

    def test_old_handoff_uses_durable_watchdog_retry_budget(self):
        result, calls = self.check([self.row()], sent='2026-11-02T18:00:00Z')
        self.assertEqual(calls, 0)
        self.assertEqual(result['status'], 'awaiting_watchdog_recovery')

    def test_terminal_and_problematic_cards_are_not_reopened(self):
        result, calls = self.check([self.row(x) for x in ['explained', 'deleted', 'published', 'problematic']])
        self.assertEqual(calls, 0)
        self.assertEqual(result['pending_count'], 0)

    def test_both_radar_producers_call_guard_after_persistence(self):
        for name in ['update.yml', 'ttendencias-refresh.yml']:
            text = (ROOT / '.github/workflows' / name).read_text()
            self.assertIn('issues: read', text)
            at = text.index('python3 trends/ensure_pc_editorial.py')
            self.assertGreater(at, text.index('git push origin HEAD:main'))


if __name__ == '__main__':
    unittest.main()
