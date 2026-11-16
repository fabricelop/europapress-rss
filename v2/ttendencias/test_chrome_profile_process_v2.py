#!/usr/bin/env python3
"""Regression: one V2 worker must never kill another Chrome profile."""
import json
import os
import pathlib
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).parent))
os.environ.setdefault('LOCALAPPDATA', tempfile.gettempdir())
from chrome_profile_process_v2 import (
    command_line_profile, exact_chrome_profile_pids, matching_pids)
import image_worker_v2 as image_worker
import editorial_run_v2 as editorial_run


class ExactChromeProfileTests(unittest.TestCase):
    def test_profile_parser_supports_all_windows_quoting_patterns(self):
        profile = r"C:\Users\A B\AppData\Local\TTActualidadV2\ChromeProfileImages"
        commands = (
            'chrome.exe "--user-data-dir=' + profile + '" --new-window',
            'chrome.exe --user-data-dir="' + profile + '" --new-window',
            'chrome.exe --user-data-dir=' + profile.replace('A B', 'AB') + ' --new-window'
        )
        for command in commands[:2]:
            with self.subTest(command=command):
                self.assertEqual(command_line_profile(command), profile.lower())
        self.assertEqual(command_line_profile(commands[2]),
                         profile.replace('A B', 'AB').lower())

    def test_prefixes_and_parallel_slots_are_not_profile_owners(self):
        root = r"C:\Users\X\AppData\Local\TTActualidadV2"
        records = [
            {"ProcessId": 1, "CommandLine": 'chrome.exe --user-data-dir=' + root + r'\ChromeProfile'},
            {"ProcessId": 2, "CommandLine": 'chrome.exe --user-data-dir=' + root + r'\ChromeProfileImages'},
            {"ProcessId": 3, "CommandLine": 'chrome.exe --user-data-dir=' + root + r'\ChromeProfileImages-Parallel-01'},
            {"ProcessId": 4, "CommandLine": 'chrome.exe --user-data-dir=' + root + r'\ChromeProfile-Parallel-01'},
            {"ProcessId": 5, "CommandLine": 'chrome.exe --user-data-dir=' + root + r'\ChromeProfileImages-Parallel-01.building'},
        ]
        self.assertEqual(matching_pids(records, root + r'\ChromeProfile'), {1})
        self.assertEqual(matching_pids(records, root + r'\ChromeProfileImages'), {2})
        self.assertEqual(matching_pids(records, root + r'\ChromeProfileImages-Parallel-01'), {3})
        self.assertEqual(matching_pids(records, root + r'\ChromeProfile-Parallel-01'), {4})
        self.assertEqual(matching_pids(records, root + r'\ChromeProfileImages-Parallel-01.building'), {5})

    def test_powershell_enumeration_filters_without_logging_command_lines(self):
        records = [
            {"ProcessId": 31, "CommandLine": r'chrome.exe --user-data-dir=C:\TT\ChromeProfileImages'},
            {"ProcessId": 32, "CommandLine": r'chrome.exe --user-data-dir=C:\TT\ChromeProfileImages-Parallel-01'},
        ]
        with patch('chrome_profile_process_v2.subprocess.run',
                   return_value=SimpleNamespace(returncode=0, stdout=json.dumps(records))) as run:
            self.assertEqual(exact_chrome_profile_pids(r'C:\TT\ChromeProfileImages'), {31})
        self.assertIn('ProcessId,CommandLine', run.call_args.args[0][-1])

    def test_failed_enumeration_fails_closed(self):
        with patch('chrome_profile_process_v2.subprocess.run',
                   return_value=SimpleNamespace(returncode=1, stdout='')):
            with self.assertRaisesRegex(RuntimeError, 'INSPECTION_FAILED'):
                exact_chrome_profile_pids(r'C:\TT\ChromeProfileImages')

    def test_editorial_and_image_workers_use_exact_profile_identity(self):
        with (patch.object(editorial_run, 'exact_chrome_profile_pids', return_value={11}) as editor,
              patch.object(image_worker, 'exact_chrome_profile_pids', return_value={22}) as image):
            self.assertEqual(editorial_run.profile_pids(), {11})
            self.assertEqual(image_worker.image_profile_pids(), {22})
        editor.assert_called_once_with(editorial_run.PROFILE)
        image.assert_called_once_with(image_worker.PROFILE)


if __name__ == '__main__':
    unittest.main()
