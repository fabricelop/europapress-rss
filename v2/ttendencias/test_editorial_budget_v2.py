"""News and Trends reserve a shared GitHub API budget for in-flight work."""
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
os.environ.setdefault('LOCALAPPDATA', tempfile.gettempdir())
import editorial_github_access_v2 as access


class SharedBudgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = pathlib.Path(self.tmp.name)
        budget = patch.object(access, 'BUDGET', root / 'github-api-budget.json')
        cooldown = patch.object(access, 'COOLDOWN', root / 'github-api-cooldown.json')
        budget.start()
        cooldown.start()
        self.addCleanup(budget.stop)
        self.addCleanup(cooldown.stop)

    def test_budget_below_reserve_blocks_new_work(self):
        access._remember_budget({'X-RateLimit-Remaining': '799',
                                 'X-RateLimit-Reset': '2000'}, clock=lambda: 1000)
        self.assertTrue(access.budget_low(clock=lambda: 1300))
        access._remember_budget({'X-RateLimit-Remaining': '800',
                                 'X-RateLimit-Reset': '2000'}, clock=lambda: 1300)
        self.assertEqual(json.loads(access.BUDGET.read_text())['remaining'], 799)
        self.assertFalse(access.budget_low(clock=lambda: 2001))

    def test_high_budget_does_not_pause_new_work(self):
        access._remember_budget({'X-RateLimit-Remaining': '1400',
                                 'X-RateLimit-Reset': '2000'}, clock=lambda: 1000)
        self.assertFalse(access.BUDGET.exists())
        self.assertFalse(access.budget_low(clock=lambda: 1300))

    def test_existing_quota_cooldown_is_shared_with_news(self):
        access.COOLDOWN.write_text('{"until": 1700}')
        self.assertTrue(access.budget_low(clock=lambda: 1200))
        self.assertFalse(access.budget_low(clock=lambda: 1701))


if __name__ == '__main__':
    unittest.main()
