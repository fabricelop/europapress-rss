"""Native News-only process ownership checks; no live Windows processes."""
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import psutil

from .news_process_inspection_v2 import (_profile_arg, chrome_profile_pids,
                                         listener_pids)
from .editorial_browser_v2 import ChromeJob, verify_endpoint_owned


PROFILE = r'C:\Users\News\sessions\123\Profile'


def process(pid, name, *args):
    return SimpleNamespace(info={'pid': pid, 'name': name, 'cmdline': list(args)})


class NativeOwnershipTests(unittest.TestCase):
    def test_quoted_exact_profile_only_never_neighbor_or_other_chrome(self):
        candidates = [
            process(21, 'chrome.exe', 'chrome.exe', '--user-data-dir=' + PROFILE),
            process(22, 'chrome.exe', 'chrome.exe', '--user-data-dir=' + PROFILE + '-Images'),
            process(23, 'chrome.exe', 'chrome.exe', '--user-data-dir=' + PROFILE.lower()),
            process(24, 'msedge.exe', 'msedge.exe', '--user-data-dir=' + PROFILE),
            process(25, 'chrome.exe', 'chrome.exe', '--user-data-dir', PROFILE),
        ]
        self.assertEqual(chrome_profile_pids(Path(PROFILE), process_iter=lambda attrs: candidates),
                         {21, 23, 25})
        self.assertEqual(_profile_arg(['chrome.exe', '--user-data-dir="' + PROFILE + '"']),
                         _profile_arg(['chrome.exe', '--user-data-dir=' + PROFILE]))

    def test_refuses_uninspectable_chrome_instead_of_falsely_releasing(self):
        candidates = [process(21, 'chrome.exe')]
        with self.assertRaisesRegex(RuntimeError, 'NEWS_CHROME_PROCESS_INSPECTION_UNAVAILABLE'):
            chrome_profile_pids(PROFILE, process_iter=lambda attrs: candidates)

    def test_refuses_access_denied_process_scan(self):
        class Denied:
            @property
            def info(self):
                raise psutil.AccessDenied(29)
        with self.assertRaisesRegex(RuntimeError, 'NEWS_CHROME_PROCESS_INSPECTION_UNAVAILABLE'):
            chrome_profile_pids(PROFILE, process_iter=lambda attrs: [Denied()])

    def test_only_exact_local_listening_port_qualifies(self):
        def socket(pid, port, ip='127.0.0.1', status=psutil.CONN_LISTEN):
            return SimpleNamespace(pid=pid, status=status,
                                   laddr=SimpleNamespace(ip=ip, port=port))
        entries = [socket(21, 31555), socket(22, 31556),
                   socket(23, 31555, ip='::1'), socket(24, 31555, status='ESTABLISHED')]
        self.assertEqual(listener_pids(31555, connections=lambda **kw: entries), {21})
        for port in (9223, 9234, 22, 65536, '31555'):
            with self.subTest(port=port), self.assertRaisesRegex(RuntimeError, 'NEWS_CDP_PORT_INVALID'):
                listener_pids(port, connections=lambda **kw: entries)

    def test_endpoint_requires_listener_and_exact_profile_owner(self):
        self.assertTrue(verify_endpoint_owned(31555, PROFILE,
            find_pids=lambda p: {21, 22}, listeners=lambda port: {21}))
        with self.assertRaisesRegex(RuntimeError, 'NEWS_CDP_ENDPOINT_NOT_OWNED'):
            verify_endpoint_owned(31555, PROFILE,
                find_pids=lambda p: {21, 22}, listeners=lambda port: {23})

    def test_one_send_hides_real_window_after_fill_before_enter(self):
        order = []
        browser = object.__new__(ChromeJob)
        browser.sent = False
        browser.page = SimpleNamespace(bring_to_front=lambda: order.append('front'))
        browser.composer = SimpleNamespace(fill=lambda _: order.append('fill'),
                                          press=lambda _: order.append('enter'))
        browser.hider = SimpleNamespace(ensure_hidden=lambda: order.append('hidden'))
        browser.send_once('private prompt')
        self.assertEqual(order, ['front', 'fill', 'hidden', 'enter'])
        with self.assertRaisesRegex(RuntimeError, 'NEWS_SEND_NOT_AUTHORIZED'):
            browser.send_once('again')

    def test_visible_chrome_never_sends(self):
        order = []
        browser = object.__new__(ChromeJob)
        browser.sent = False
        browser.page = SimpleNamespace(bring_to_front=lambda: None)
        browser.composer = SimpleNamespace(fill=lambda _: order.append('fill'),
                                          press=lambda _: order.append('enter'))
        def visible():
            raise RuntimeError('V2_CHROME_WINDOW_VISIBLE')
        browser.hider = SimpleNamespace(ensure_hidden=visible)
        with self.assertRaisesRegex(RuntimeError, 'V2_CHROME_WINDOW_VISIBLE'):
            browser.send_once('not sent')
        self.assertEqual(order, ['fill'])
        self.assertTrue(browser.sent)  # No second Enter even on uncertain failure.


if __name__ == '__main__':
    unittest.main()
