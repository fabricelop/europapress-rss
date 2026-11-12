import base64
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from datetime import datetime, timezone

spec = importlib.util.spec_from_file_location('guard', Path(__file__).resolve().parents[1] / 'shared/tt_editorial_run_guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class TriggerConflictTests(unittest.TestCase):
    now = datetime(2026, 11, 2, 19, 0, tzinfo=timezone.utc)

    def run_request(self, failures, concurrent=False):
        writes, reads = [], []
        def api(path, method='GET', payload=None, branch=None):
            if method == 'GET':
                reads.append(branch)
                doc = {'command_id': 'old', 'requested_at': '2026-11-02T16:00:00Z'}
                if concurrent and len(reads) > 1:
                    doc = {'command_id': 'other-run', 'requested_at': self.now.isoformat()}
                return {'sha': 'sha-' + str(len(reads)), 'content': base64.b64encode(json.dumps(doc).encode()).decode()}
            writes.append(payload)
            if len(writes) <= failures:
                raise RuntimeError('GITHUB_HTTP_409 branch head moved')
            return {}
        pending = [{'id': 'same-card', 'title': 'Same card', 'revision': 0}]
        with patch.object(guard, 'api', api), patch.object(guard.time, 'sleep'), patch.object(guard, 'pending', return_value=pending):
            result = guard.request('ttendencias', self.now, {'pending_ids': ['same-card']})
        return result, writes, reads

    def test_branch_conflict_reloads_sha_and_retries_same_command(self):
        result, writes, reads = self.run_request(2)
        self.assertTrue(result['requested'])
        self.assertEqual([x['sha'] for x in writes], ['sha-1', 'sha-2', 'sha-3'])
        self.assertEqual(len({x['content'] for x in writes}), 1)
        self.assertEqual(reads, ['control/ttendencias-run-trigger'] * 3)
        doc = json.loads(base64.b64decode(writes[-1]['content']))
        self.assertFalse(doc['auto_image_followup'])
        self.assertEqual(doc['pending_ids'], ['same-card'])

    def test_concurrent_editorial_command_is_preserved(self):
        result, writes, reads = self.run_request(1, concurrent=True)
        self.assertFalse(result['requested'])
        self.assertEqual(result['command_id'], 'other-run')
        self.assertEqual(len(writes), 1)

    def test_conflict_retry_is_bounded(self):
        with self.assertRaisesRegex(RuntimeError, 'GITHUB_HTTP_409'):
            self.run_request(5)

    def test_auth_failure_is_not_retried(self):
        with patch.object(guard, 'api', side_effect=RuntimeError('GITHUB_HTTP_403 denied')) as api, patch.object(guard, 'pending', return_value=[]):
            with self.assertRaisesRegex(RuntimeError, 'GITHUB_HTTP_403'):
                guard.request('ttendencias', self.now, {'pending_ids': []})
            self.assertEqual(api.call_count, 1)


if __name__ == '__main__':
    unittest.main()
