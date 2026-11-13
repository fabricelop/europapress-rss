#!/usr/bin/env python3
"""Tests the Windows Chrome launcher-to-CDP transition without a browser."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from chrome_startup_v2 import wait_for_cdp, ChromeStartupError


class MockProcess:
    def __init__(self, codes):
        self.codes = list(codes)
        self.calls = 0

    def poll(self):
        i = min(self.calls, len(self.codes) - 1)
        self.calls += 1
        return self.codes[i]


class ChromeStartupTests(unittest.TestCase):
    def test_launcher_exits_zero_but_child_cdp_comes_up(self):
        probes = iter([False, False, True])
        proc = MockProcess([0] * 10)
        result = wait_for_cdp(proc, lambda: next(probes),
                              lambda: {371}, attempts=5,
                              delay=lambda _: None)
        self.assertTrue(result["ready"])
        self.assertTrue(result["launcher_exited"])
        self.assertTrue(result["children_seen"])
        self.assertEqual(result["launcher_code"], 0)

    def test_launcher_alive_then_cdp_ready(self):
        probes = iter([False, True])
        result = wait_for_cdp(MockProcess([None] * 6),
                              lambda: next(probes), lambda: set(),
                              attempts=5, delay=lambda _: None)
        self.assertTrue(result["ready"])
        self.assertFalse(result["launcher_exited"])

    def test_launcher_exits_without_children_is_failure_not_success(self):
        with self.assertRaisesRegex(ChromeStartupError, "no V2 browser process"):
            wait_for_cdp(MockProcess([0] * 20), lambda: False,
                         lambda: set(), attempts=10,
                         absent_limit=3, delay=lambda _: None)

    def test_launcher_crashes_nonzero_error_contains_exit_code(self):
        with self.assertRaisesRegex(ChromeStartupError, "exit=42"):
            wait_for_cdp(MockProcess([42] * 20), lambda: False,
                         lambda: set(), attempts=8, absent_limit=2,
                         delay=lambda _: None)

    def test_child_stays_but_no_cdp_reports_timeout(self):
        with self.assertRaisesRegex(ChromeStartupError, "child_process_seen=YES"):
            wait_for_cdp(MockProcess([0] * 20), lambda: False,
                         lambda: {1300}, attempts=4,
                         delay=lambda _: None)

    def test_rejects_zero_limits(self):
        with self.assertRaises(ValueError):
            wait_for_cdp(MockProcess([0]), lambda: False, lambda: set(),
                         attempts=0)


if __name__ == "__main__":
    unittest.main()
