#!/usr/bin/env python3
"""Unit tests for V2-only Chrome cleanup; no Windows, Chrome or messages."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from chrome_cleanup_v2 import cleanup_v2_profile


class CleanupTests(unittest.TestCase):
    def test_late_child_is_cleaned_and_two_empty_rounds_required(self):
        sequence = iter([{101,102},{102,103},{103},set(),set()])
        killed = []
        result = cleanup_v2_profile(
            lambda: next(sequence), kill_pid=lambda p: killed.append(p) or 0,
            sleep=lambda _: None, max_rounds=6)
        self.assertTrue(result["closed"])
        self.assertEqual(result["rounds"],5)
        self.assertEqual(result["seen"],[101,102,103])
        self.assertEqual(killed,[101,102,102,103,103])

    def test_empty_profile_does_not_kill_anything(self):
        killed = []
        result = cleanup_v2_profile(lambda: set(),
                 kill_pid=lambda pid:killed.append(pid) or 0, sleep=lambda _: None)
        self.assertTrue(result["closed"])
        self.assertEqual(result["rounds"],2)
        self.assertEqual(killed,[])

    def test_failed_taskkill_does_not_claim_success_if_still_present(self):
        result = cleanup_v2_profile(lambda:{100}, kill_pid=lambda _:5,
                                   sleep=lambda _:None, max_rounds=3)
        self.assertFalse(result["closed"])
        self.assertEqual(result["remaining"],[100])
        self.assertEqual(result["kill_failures"]["100"],"taskkill_exit_5")

    def test_processes_disappearing_during_kill_are_not_an_error(self):
        sequence=iter([{7}, set(), set()])
        result=cleanup_v2_profile(lambda:next(sequence), kill_pid=lambda _:128,
                                  sleep=lambda _:None)
        self.assertTrue(result["closed"])

    def test_no_unscoped_process_discovery(self):
        # The cleanup helper never looks up Chrome on its own; its caller
        # supplies V2-profile-scoped PIDs, thereby never receiving V1 PIDs.
        v2_processes=iter([{41}, set(), set()])
        killed=[]
        result=cleanup_v2_profile(lambda:next(v2_processes),
                                  kill_pid=lambda p:killed.append(p) or 0,
                                  sleep=lambda _:None)
        self.assertTrue(result["closed"])
        self.assertEqual(killed,[41])
        self.assertNotIn(9223,killed)

    def test_bad_round_count_refused(self):
        with self.assertRaises(ValueError):
            cleanup_v2_profile(lambda: set(), max_rounds=1)


if __name__ == "__main__":
    unittest.main()
