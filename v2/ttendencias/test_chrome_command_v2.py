#!/usr/bin/env python3
"""No-window command tests, no real Chrome or network."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from chrome_command_v2 import command


class ChromeCommandTests(unittest.TestCase):
    def test_headless_keeps_isolated_profile_and_cdp(self):
        args = command("C:/Chrome/chrome.exe", "C:/Test/TTActualidadV2/ChromeProfile",
                       47331, headless=True)
        self.assertIn("--headless=new", args)
        self.assertIn("--user-data-dir=C:/Test/TTActualidadV2/ChromeProfile", args)
        self.assertIn("--remote-debugging-port=47331", args)
        self.assertIn("--remote-debugging-address=127.0.0.1", args)
        self.assertNotIn("--new-window", args)
        self.assertEqual(args[-1], "https://chatgpt.com/")

    def test_visible_mode_is_reversible_for_diagnostics(self):
        args = command("chrome.exe", "C:/Test/V2", 47331, headless=False)
        self.assertIn("--new-window", args)
        self.assertNotIn("--headless=new", args)

    def test_cannot_touch_v1_ports(self):
        for port in (9223, 9234):
            with self.assertRaises(ValueError):
                command("chrome.exe", "C:/Test/V2", port)

    def test_invalid_port_refused(self):
        for port in (0, 80, 65536):
            with self.assertRaises(ValueError):
                command("chrome.exe", "C:/Test/V2", port)

if __name__ == "__main__":
    unittest.main()
