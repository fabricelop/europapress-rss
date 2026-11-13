#!/usr/bin/env python3
"""Safe Win32 API smoke: no Chrome launched or other process/window modified."""
import os
import unittest

from v2.ttendencias.chrome_visibility_v2 import (
    startupinfo_hidden, hide_windows_for_pids, visible_windows_for_pids)


@unittest.skipUnless(os.name == "nt", "Windows-only Win32 callback API")
class HiddenChromeWin32Tests(unittest.TestCase):
    def test_hidden_startupinfo(self):
        import subprocess
        flags = startupinfo_hidden()
        self.assertIsInstance(flags, subprocess.STARTUPINFO)
        self.assertTrue(flags.dwFlags & subprocess.STARTF_USESHOWWINDOW)
        self.assertEqual(flags.wShowWindow, 0)

    def test_empty_set_does_nothing(self):
        self.assertEqual(visible_windows_for_pids(set()), 0)
        self.assertEqual(hide_windows_for_pids(set()), 0)

    def test_nonexistent_pid_safe_win32_enum(self):
        # No real process can use an out-of-range Windows PID; this
        # exercises the actual EnumWindows callback without hiding a window.
        nobody = {0xFFFFFFFF}
        self.assertEqual(visible_windows_for_pids(nobody), 0)
        self.assertEqual(hide_windows_for_pids(nobody), 0)


if __name__ == "__main__":
    unittest.main()
