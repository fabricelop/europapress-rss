"""Editorial-only GitHub quota reductions; no real network or Chrome."""
import copy
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from . import editorial_consumer_v2 as consumer
from .radar_store_v2 import REPOSITORY, StoreError


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.budget_patch = patch.object(consumer, '_GH_BUDGET', root / 'budget.json')
        self.cooldown_patch = patch.object(consumer, '_GH_COOLDOWN', root / 'cooldown.json')
        self.budget_patch.start()
        self.cooldown_patch.start()
        self.addCleanup(self.budget_patch.stop)
        self.addCleanup(self.cooldown_patch.stop)

    def test_low_budget_stops_new_claims_but_expires_at_reset(self):
        consumer._note_budget({'X-RateLimit-Remaining': '700',
                               'X-RateLimit-Reset': '1500'}, clock=lambda: 1000)
        self.assertTrue(consumer._budget_low(clock=lambda: 1200))
        consumer._note_budget({'x-ratelimit-remaining': '730',
                               'x-ratelimit-reset': '1500'}, clock=lambda: 1100)
        self.assertEqual(json.loads(consumer._GH_BUDGET.read_text())['remaining'], 700)
        self.assertFalse(consumer._budget_low(clock=lambda: 1501))

    def test_rate_limit_403_shares_cooldown(self):
        error = HTTPError('https://api.github.com/', 403, 'limited',
                          {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1800'},
                          io.BytesIO(b'{"message":"API rate limit exceeded"}'))
        self.assertTrue(consumer._remember_limit(error, clock=lambda: 1000))
        self.assertEqual(consumer._cooldown_remaining(clock=lambda: 1001), 802)
        self.assertTrue(consumer._budget_low(clock=lambda: 1001))

    def test_unrelated_403_does_not_claim_rate_limit(self):
        error = HTTPError('https://api.github.com/', 403, 'forbidden', {},
                          io.BytesIO(b'{"message":"Resource not accessible"}'))
        self.assertFalse(consumer._remember_limit(error, clock=lambda: 1000))
        self.assertFalse(consumer._GH_COOLDOWN.exists())


class FakeResponse:
    def __init__(self, raw, headers=None):
        self.raw = raw
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, _limit):
        return self.raw


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.patch_budget = patch.object(consumer, '_GH_BUDGET', root / 'budget.json')
        self.patch_cooldown = patch.object(consumer, '_GH_COOLDOWN', root / 'cooldown.json')
        self.patch_budget.start()
        self.patch_cooldown.start()
        self.addCleanup(self.patch_budget.stop)
        self.addCleanup(self.patch_cooldown.stop)

    def test_unchanged_authenticated_branch_304_returns_cached_head(self):
        store = consumer.EconomicalEditorialStore('fake-token')
        route = '/repos/' + REPOSITORY + '/branches/feature%2Fttactualidad-v2-clean'
        response = FakeResponse(json.dumps({'commit': {'sha': 'a' * 40}}).encode(),
                                {'ETag': '"branch-etag"'})
        unchanged = HTTPError('https://api.github.com/' + route, 304, 'Not modified',
                              {}, io.BytesIO())
        store._opener = Mock()
        store._opener.open.side_effect = [response, unchanged]
        self.assertEqual(store.head(), 'a' * 40)
        self.assertEqual(store.head(), 'a' * 40)
        sent = store._opener.open.call_args_list[1].args[0]
        self.assertEqual(sent.get_header('If-none-match'), '"branch-etag"')

    def test_snapshot_is_read_only_once_per_head_and_copies_returned_docs(self):
        store = consumer.EconomicalEditorialStore('fake-token')
        head = 'b' * 40
        store.head = Mock(return_value=head)
        event = 'v2/ttittulares/news/ttn2-' + 'a' * 24 + '.json'
        image_binary = 'v2/ttittulares/images/ttn2-' + 'a' * 24 + '-r1-x.png'
        store.inventory = Mock(return_value={
            event: {'type': 'blob'}, image_binary: {'type': 'blob'},
        })
        store.read_documents = Mock(return_value={event: {'value': 1}})
        _, first = store.read_editorial_snapshot()
        first[event]['value'] = 77
        _, second = store.read_editorial_snapshot()
        self.assertEqual(second[event]['value'], 1)
        store.inventory.assert_called_once_with(head)
        store.read_documents.assert_called_once_with(head, [event])
        store.head.return_value = 'c' * 40
        store.read_editorial_snapshot()
        self.assertEqual(store.inventory.call_count, 2)

    def test_rate_limit_403_is_not_treated_as_auth_failure(self):
        store = consumer.EconomicalEditorialStore('fake-token')
        error = HTTPError('https://api.github.com/', 403, 'limited',
                          {'X-RateLimit-Remaining': '0',
                           'X-RateLimit-Reset': str(int(consumer.time.time()) + 120)},
                          io.BytesIO(b'{"message":"API rate limit exceeded"}'))
        store._opener = Mock()
        store._opener.open.side_effect = error
        with self.assertRaisesRegex(StoreError, 'GITHUB_RATE_LIMIT_PAUSED'):
            store.head()


if __name__ == '__main__':
    unittest.main()
