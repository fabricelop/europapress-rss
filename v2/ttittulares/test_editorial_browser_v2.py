"""No browser/Windows mutation: deterministic capture and cleanup fault tests."""
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from .editorial_browser_v2 import (
    ChromeJob, STOP, authenticated_session, capture_reply, confirm_user_turn, listener_process_ids,
    verify_endpoint_owned, read_news_turns, fresh_home_page,
)
from .probe_news_chat_response_v2 import PROBE, observe_probe
from .probe_news_existing_chat_v2 import inspect_chat, validated_chat_url

EVENT, REVISION, COMMAND = 'ttn2-' + 'a' * 24, 2, 'news-command-1'
USER = json.dumps({'event_id': EVENT, 'revision': REVISION, 'command_id': COMMAND})
ANSWER = 'TTN2_EDITORIAL_BEGIN\n{"complete":"synthetic"}\nTTN2_EDITORIAL_END'


class Clock:
    def __init__(self): self.now = 0
    def __call__(self): return self.now
    def sleep(self, seconds): self.now += seconds


class Page:
    def __init__(self, clock, *, users=None, answers=None, busy=None, url=None):
        self.clock = clock
        self.users = users or (lambda seconds: [USER])
        self.answers = answers or (lambda seconds: [ANSWER])
        self.busy = busy or (lambda seconds: False)
        self.url_at = url or (lambda seconds: 'https://chatgpt.com/c/own-conversation')
    @property
    def url(self): return self.url_at(self.clock())
    def locator(self, selector):
        if selector == STOP:
            return SimpleNamespace(count=lambda: int(self.busy(self.clock())))
        source = self.users if '="user"' in selector or 'data-user-message-bubble' in selector else self.answers
        return SimpleNamespace(all_text_contents=lambda: source(self.clock()))


class TranscriptPage(Page):
    def __init__(self, clock, transcript, **kwargs):
        super().__init__(clock, users=lambda _: [], answers=lambda _: [], **kwargs)
        self.transcript = transcript
    def locator(self, selector):
        if selector == 'body':
            return SimpleNamespace(inner_text=lambda **kw: self.transcript)
        return super().locator(selector)


class BrowserBoundaryTests(unittest.TestCase):
    def test_existing_chat_probe_refuses_arbitrary_navigation(self):
        accepted = 'https://chatgpt.com/g/g-p-project/c/chat-123'
        self.assertEqual(validated_chat_url(accepted + '?model=foo'), accepted)
        for unsafe in ('http://chatgpt.com/c/chat-123',
                       'https://evil.example/c/chat-123',
                       'https://chatgpt.com/share/chat-123',
                       'https://user:pass@chatgpt.com/c/chat-123'):
            with self.subTest(url=unsafe), self.assertRaisesRegex(RuntimeError, 'CHAT_URL_INVALID'):
                validated_chat_url(unsafe)

    def test_existing_chat_probe_returns_only_content_free_dom_evidence(self):
        class DiagnosticPage:
            url = 'https://chatgpt.com/c/owned-chat'
            def locator(self, selector):
                values = {
                    '[data-message-author-role="user"]': ['private original prompt'],
                    '[data-message-author-role="assistant"]': ['TTN2_EDITORIAL_BLOCKED: no news'],
                    '[data-message-author-role="assistant"] .markdown': ['TTN2_EDITORIAL_BLOCKED: no news'],
                }.get(selector, [])
                return SimpleNamespace(
                    count=lambda: len(values),
                    all_text_contents=lambda **kwargs: values,
                    inner_text=lambda **kwargs: 'private original prompt\nTTN2_EDITORIAL_BLOCKED: no news',
                )
        result = inspect_chat(DiagnosticPage())
        self.assertEqual(result['assistant_role_nonempty'], 1)
        self.assertEqual(result['assistant_markdown_nonempty'], 1)
        self.assertEqual(result['extracted_assistant_turns'], 1)
        self.assertNotIn('private', json.dumps(result))
        self.assertNotIn('owned-chat', json.dumps(result))

    def test_short_probe_follows_exact_chat_on_another_owned_tab(self):
        clock = Clock()
        home = Page(clock, url=lambda _: 'https://chatgpt.com/')
        unrelated = Page(clock, users=lambda _: ['Another question'],
                         answers=lambda _: ['TTN2_PROBE_OK'])
        actual = Page(clock, users=lambda _: [PROBE],
                      answers=lambda _: ['TTN2_PROBE_OK'])
        browser = SimpleNamespace(browser=SimpleNamespace(contexts=[
            SimpleNamespace(pages=[home, unrelated, actual])]))
        observed = observe_probe(browser)
        for key, expected in {'submission_confirmed': True, 'assistant_turns': 1,
                              'response_seen': True, 'probe_ok': True,
                              'stop_visible': False, 'owned_pages_seen': 3,
                              'chat_pages_seen': 2, 'probe_user_pages': 1}.items():
            self.assertEqual(observed[key], expected)

    def test_short_probe_accepts_whitespace_and_short_ui_label_in_user_turn(self):
        clock = Clock()
        edited = PROBE.replace(' Noticias ', '\nNoticias ') + '\nEdit'
        page = Page(clock, users=lambda _: [edited], answers=lambda _: ['TTN2_PROBE_OK'])
        browser = SimpleNamespace(browser=SimpleNamespace(contexts=[
            SimpleNamespace(pages=[page])]))
        observed = observe_probe(browser)
        self.assertTrue(observed['submission_confirmed'])
        self.assertTrue(observed['probe_ok'])

    def test_short_probe_reports_reply_without_permanent_chat_route(self):
        clock = Clock()
        page = Page(clock, users=lambda _: [PROBE], answers=lambda _: ['TTN2_PROBE_OK'],
                    url=lambda _: 'https://chatgpt.com/')
        browser = SimpleNamespace(browser=SimpleNamespace(contexts=[
            SimpleNamespace(pages=[page])]))
        observed = observe_probe(browser)
        self.assertFalse(observed['submission_confirmed'])
        self.assertEqual(observed['assistant_pages_seen'], 1)
        self.assertEqual(observed['probe_user_pages'], 1)
        self.assertTrue(observed['probe_reply_without_chat_url'])

    def test_short_probe_does_not_guess_between_two_matching_chats(self):
        clock = Clock()
        first = Page(clock, users=lambda _: [PROBE], answers=lambda _: ['TTN2_PROBE_OK'])
        other = Page(clock, users=lambda _: [PROBE], answers=lambda _: ['TTN2_PROBE_OK'],
                     url=lambda _: 'https://chatgpt.com/c/second-conversation')
        browser = SimpleNamespace(browser=SimpleNamespace(contexts=[
            SimpleNamespace(pages=[first, other])]))
        self.assertFalse(observe_probe(browser)['submission_confirmed'])
        self.assertFalse(observe_probe(browser)['probe_ok'])

    def test_windows_launcher_exit_does_not_reject_owned_child_that_becomes_ready(self):
        from .editorial_browser_v2 import common
        startup = common('chrome_startup_v2')
        process = SimpleNamespace(poll=lambda: 0)
        probes = iter([False, False, True])
        result = startup.wait_for_cdp(process, lambda: next(probes), lambda: {55},
                                      attempts=5, delay=lambda _: None)
        self.assertTrue(result['ready'])
        self.assertTrue(result['launcher_exited'])
        self.assertTrue(result['children_seen'])

    def test_windows_launcher_without_any_owned_browser_reports_actual_exit_code(self):
        from .editorial_browser_v2 import common
        startup = common('chrome_startup_v2')
        with self.assertRaisesRegex(startup.ChromeStartupError, 'exit=42'):
            startup.wait_for_cdp(SimpleNamespace(poll=lambda: 42), lambda: False,
                                 lambda: set(), attempts=8, absent_limit=2, delay=lambda _: None)

    def capture(self, page, clock, heartbeat=lambda: None, timeout=90):
        return capture_reply(page, event_id=EVENT, revision=REVISION,
            command_id=COMMAND, heartbeat=heartbeat, timeout=timeout,
            clock=clock, sleep=clock.sleep)

    def confirm(self, page, clock, heartbeat=lambda: None, timeout=90):
        return confirm_user_turn(page, event_id=EVENT, revision=REVISION,
            command_id=COMMAND, heartbeat=heartbeat, timeout=timeout,
            clock=clock, sleep=clock.sleep)

    def test_reuses_only_empty_home_tab_and_skips_broken_tabs(self):
        def tab(url, count=0):
            return SimpleNamespace(url=url, locator=lambda selector:
                                   SimpleNamespace(count=lambda: count))
        broken = SimpleNamespace(url='https://chatgpt.com/',
                                 locator=lambda selector: 1 / 0)
        old_chat = tab('https://chatgpt.com/c/old')
        occupied_home = tab('https://chatgpt.com/', 1)
        empty_home = tab('https://chatgpt.com/')
        context = SimpleNamespace(pages=[broken, old_chat, occupied_home, empty_home])
        self.assertIs(fresh_home_page(context), empty_home)
        self.assertIsNone(fresh_home_page(SimpleNamespace(pages=[old_chat, occupied_home])))

    def test_visible_assistant_reply_with_role_user_is_captured(self):
        clock = Clock()
        transcript = 'You said:\n' + USER + '\nChatGPT said:\n' + ANSWER
        page = TranscriptPage(clock, transcript)
        page.users = lambda _: [USER]
        self.assertEqual(self.capture(page, clock), (ANSWER, page.url))

    def test_no_role_dom_uses_full_visible_pair_over_truncated_bubble(self):
        """Regression for actual Windows evidence: role=0, labels=1+1."""
        clock = Clock()
        class TruncatedBubblePage(TranscriptPage):
            def locator(self, selector):
                if selector == '[data-user-message-bubble="true"]':
                    return SimpleNamespace(all_text_contents=lambda: ['Show more'])
                return super().locator(selector)
        page = TruncatedBubblePage(clock, 'You said:\n' + USER + '\nChatGPT said:\n' + ANSWER)
        users, answers = read_news_turns(page)
        self.assertEqual(users, [USER])
        self.assertEqual(answers, [ANSWER])
        self.assertEqual(self.capture(page, clock), (ANSWER, page.url))

    def test_no_role_dom_confirms_full_visible_user_while_reply_is_pending(self):
        clock = Clock()
        class TruncatedBubblePage(TranscriptPage):
            def locator(self, selector):
                if selector == '[data-user-message-bubble="true"]':
                    return SimpleNamespace(all_text_contents=lambda: ['Show more'])
                return super().locator(selector)
        page = TruncatedBubblePage(clock, 'You said:\n' + USER +
                                   '\nChatGPT can make mistakes.\nLatest response')
        self.assertEqual(read_news_turns(page), ([USER], []))
        self.assertEqual(self.confirm(page, clock), page.url)
        with self.assertRaisesRegex(RuntimeError, 'CAPTURE_TIMEOUT_NO_RESEND'):
            self.capture(page, clock, timeout=12)

    def test_assistant_quote_cannot_forge_single_visible_user_marker(self):
        clock = Clock()
        page = TranscriptPage(clock, 'ChatGPT said:\nYou said:\n' + USER)
        with self.assertRaisesRegex(RuntimeError, 'SUBMISSION_UNCONFIRMED'):
            self.confirm(page, clock, timeout=12)

    def test_no_role_dom_single_blocked_reply_is_incident_not_ready(self):
        clock = Clock()
        blocked = 'TTN2_EDITORIAL_BLOCKED: El candidato ficticio no tiene dos fuentes.'
        page = TranscriptPage(clock, 'You said:\n' + USER + '\nChatGPT said:\n' + blocked)
        with self.assertRaisesRegex(RuntimeError, 'NEWS_EDITORIAL_BLOCKED_NO_RESEND'):
            self.capture(page, clock)

    def test_no_role_dom_never_chooses_between_two_visible_assistant_labels(self):
        clock = Clock()
        page = TranscriptPage(clock, 'You said:\n' + USER + '\nChatGPT said:\n' +
                              ANSWER + '\nChatGPT said:\nAn unrelated reply')
        self.assertEqual(read_news_turns(page), ([], []))
        with self.assertRaisesRegex(RuntimeError, 'CAPTURE_TIMEOUT_NO_RESEND'):
            self.capture(page, clock, timeout=12)

    def test_empty_assistant_role_placeholder_does_not_hide_visible_reply(self):
        clock = Clock()
        page = TranscriptPage(clock, 'You said:\n' + USER + '\nChatGPT said:\n' + ANSWER)
        page.users = lambda _: [USER]
        page.answers = lambda _: ['  ']
        self.assertEqual(self.capture(page, clock), (ANSWER, page.url))

    def test_empty_visible_user_never_binds_unrelated_assistant(self):
        clock = Clock()
        page = TranscriptPage(clock, 'You said:\nChatGPT said:\n' + ANSWER)
        page.users = lambda _: [USER]
        self.assertEqual(read_news_turns(page), ([USER], []))
        with self.assertRaisesRegex(RuntimeError, 'CAPTURE_TIMEOUT_NO_RESEND'):
            self.capture(page, clock, timeout=12)

    def test_trends_style_last_matching_visible_pair_ignores_other_ui_markers(self):
        clock = Clock()
        transcript = ('You said:\nA sidebar example\nChatGPT said:\nNot this story.\n'
                      'You said:\n' + USER + '\nChatGPT said:\n' + ANSWER +
                      '\nChatGPT can make mistakes.\nLatest response')
        page = TranscriptPage(clock, transcript)
        page.users = lambda _: [USER]
        users, answers = read_news_turns(page)
        self.assertEqual(users, [USER])
        self.assertEqual(answers, [ANSWER])
        self.assertEqual(self.capture(page, clock), (ANSWER, page.url))

    def test_multiple_unattributed_visible_turns_never_guess_sent_identity(self):
        clock = Clock()
        transcript = ('You said:\n' + USER + '\nChatGPT said:\n' + ANSWER +
                      '\nYou said:\nOther prompt\nChatGPT said:\nOther answer')
        page = TranscriptPage(clock, transcript)
        self.assertEqual(read_news_turns(page), ([], []))
        with self.assertRaisesRegex(RuntimeError, 'CAPTURE_TIMEOUT_NO_RESEND'):
            self.capture(page, clock, timeout=12)

    def test_visible_reply_cannot_override_different_role_user(self):
        clock = Clock()
        transcript = 'You said:\n' + USER + '\nChatGPT said:\n' + ANSWER
        page = TranscriptPage(clock, transcript)
        page.users = lambda _: [USER.replace('"revision": 2', '"revision": 3')]
        with self.assertRaisesRegex(RuntimeError, 'CAPTURE_TIMEOUT_NO_RESEND'):
            self.capture(page, clock, timeout=12)

    def test_completed_markers_while_streaming_wait_for_six_idle_seconds(self):
        clock = Clock()
        page = Page(clock, busy=lambda seconds: seconds < 8)
        self.assertEqual(self.capture(page, clock), (ANSWER, page.url))
        self.assertGreaterEqual(clock.now, 14)

    def test_partial_reply_and_wrong_user_identity_never_capture(self):
        cases = [dict(answers=lambda seconds: ['TTN2_EDITORIAL_BEGIN partial']),
                 dict(users=lambda seconds: [USER.replace('"revision": 2', '"revision": 20')]),
                 dict(users=lambda seconds: [USER, USER]),
                 dict(url=lambda seconds: 'https://chatgpt.com/c/own-conversation/other')]
        for values in cases:
            with self.subTest(values=values):
                clock = Clock()
                with self.assertRaisesRegex(RuntimeError, 'CAPTURE_TIMEOUT_NO_RESEND'):
                    self.capture(Page(clock, **values), clock, timeout=12)

    def test_idle_partial_reply_fails_explicitly_without_eight_minute_watchdog(self):
        clock = Clock()
        page = Page(clock, answers=lambda _: ['TTN2_EDITORIAL_BEGIN'])
        with self.assertRaisesRegex(RuntimeError, 'NEWS_EDITORIAL_INCOMPLETE_NO_RESEND'):
            self.capture(page, clock, timeout=300)
        self.assertLess(clock.now, 70)

    def test_actively_streaming_reply_can_finish_after_partial_marker(self):
        clock = Clock()
        page = Page(clock,
            answers=lambda seconds: ['TTN2_EDITORIAL_BEGIN'] if seconds < 100 else [ANSWER],
            busy=lambda seconds: seconds < 101)
        self.assertEqual(self.capture(page, clock, timeout=140), (ANSWER, page.url))

    def test_transient_auth_check_failure_is_not_reported_as_expired_login(self):
        page = SimpleNamespace(evaluate=lambda _: None)
        with self.assertRaisesRegex(RuntimeError, 'NEWS_CHATGPT_AUTH_CHECK_UNAVAILABLE'):
            authenticated_session(page)
        self.assertFalse(authenticated_session(SimpleNamespace(evaluate=lambda _: False)))
        self.assertTrue(authenticated_session(SimpleNamespace(evaluate=lambda _: True)))

    def test_heartbeat_is_ticked_during_slow_response(self):
        clock, beats = Clock(), []
        page = Page(clock, busy=lambda seconds: seconds < 100)
        self.capture(page, clock, heartbeat=lambda: beats.append(clock()), timeout=140)
        self.assertGreaterEqual(len(beats), 2)
        self.assertTrue(all(45 <= b-a <= 47 for a, b in zip([0] + beats, beats)))

    def test_heartbeat_failure_aborts_capture_without_retry(self):
        clock = Clock()
        def failed(): raise RuntimeError('LEASE_FENCED')
        with self.assertRaisesRegex(RuntimeError, 'LEASE_FENCED'):
            self.capture(Page(clock, busy=lambda seconds: True), clock, heartbeat=failed)
        self.assertLess(clock.now, 90)

    def test_explicit_blocked_result_is_a_stable_incident_without_long_timeout(self):
        clock = Clock()
        page = Page(clock, answers=lambda seconds: ['TTN2_EDITORIAL_BLOCKED: no se confirma el hecho'])
        with self.assertRaisesRegex(RuntimeError, 'EDITORIAL_BLOCKED_NO_RESEND'):
            self.capture(page, clock)
        self.assertEqual(clock.now, 6)

    def test_authentication_check_returns_only_true_boolean_and_no_session_data(self):
        expressions = []
        page = SimpleNamespace(evaluate=lambda expression: expressions.append(expression) or True)
        self.assertTrue(authenticated_session(page))
        self.assertIn("fetch('/api/auth/session'", expressions[0])
        self.assertIn('Boolean(session && session.user && session.user.id)', expressions[0])
        for value in [False, {}, {'user': {'id': 'not-a-boolean'}}, 'true', 1]:
            with self.subTest(value=value):
                self.assertFalse(authenticated_session(SimpleNamespace(evaluate=lambda expression: value)))
        with self.assertRaisesRegex(RuntimeError, 'AUTH_CHECK_UNAVAILABLE'):
            authenticated_session(SimpleNamespace(evaluate=lambda expression: None))
        def unavailable(expression): raise RuntimeError('private details must not escape')
        with self.assertRaisesRegex(RuntimeError, 'AUTH_CHECK_UNAVAILABLE'):
            authenticated_session(SimpleNamespace(evaluate=unavailable))

    def test_confirmation_requires_exact_visible_user_turn_and_chat_url(self):
        clock = Clock()
        page = Page(clock, users=lambda seconds: [USER] if seconds >= 6 else [],
                    url=lambda seconds: 'https://chatgpt.com/c/own-conversation' if seconds >= 8 else 'https://chatgpt.com/')
        self.assertEqual(self.confirm(page, clock), 'https://chatgpt.com/c/own-conversation')
        self.assertEqual(clock.now, 8)

    def test_custom_gpt_conversation_is_accepted_only_with_exact_user_identity(self):
        url = 'https://chatgpt.com/g/g-p-news-v2/c/12345678-1234-1234-1234-123456789012'
        clock = Clock()
        page = Page(clock, url=lambda _: url)
        self.assertEqual(self.confirm(page, clock), url)
        self.assertEqual(self.capture(page, clock), (ANSWER, url))
        clock = Clock()
        with self.assertRaisesRegex(RuntimeError, 'SUBMISSION_UNCONFIRMED_NO_RESEND'):
            self.confirm(Page(clock, url=lambda _: url, users=lambda _: [USER.replace(COMMAND, 'other-command')]),
                         clock, timeout=6)

    def test_user_bubble_without_role_confirms_but_assistant_echo_never_does(self):
        class BubblePage(Page):
            def __init__(self, clock, *, bubbles):
                super().__init__(clock, users=lambda _: [], answers=lambda _: [USER])
                self.bubbles = bubbles
            def locator(self, selector):
                if selector == '[data-user-message-bubble="true"]':
                    return SimpleNamespace(all_text_contents=lambda: self.bubbles)
                if selector == 'body':
                    return SimpleNamespace(inner_text=lambda **kw: 'ChatGPT said:\n' + USER)
                return super().locator(selector)
        clock = Clock()
        self.assertEqual(self.confirm(BubblePage(clock, bubbles=[USER]), clock),
                         'https://chatgpt.com/c/own-conversation')
        clock = Clock()
        with self.assertRaisesRegex(RuntimeError, 'SUBMISSION_UNCONFIRMED_NO_RESEND'):
            self.confirm(BubblePage(clock, bubbles=[]), clock, timeout=6)

    def test_unconfirmed_enter_times_out_and_ticks_heartbeat(self):
        clock, beats = Clock(), []
        with self.assertRaisesRegex(RuntimeError, 'SUBMISSION_UNCONFIRMED_NO_RESEND'):
            self.confirm(Page(clock, users=lambda seconds: []), clock,
                         heartbeat=lambda: beats.append(clock()), timeout=60)
        self.assertEqual(len(beats), 1)

    def test_endpoint_owner_must_be_an_exact_owned_profile_process(self):
        self.assertTrue(verify_endpoint_owned(19642, Path('own'), find_pids=lambda p: {9}, listeners=lambda port: {9}))
        for own, listening in [({9}, {10}), ({9}, {9, 10}), (set(), {9}), ({9}, set())]:
            with self.subTest(own=own, listening=listening), self.assertRaisesRegex(RuntimeError, 'ENDPOINT_NOT_OWNED'):
                verify_endpoint_owned(19642, Path('own'), find_pids=lambda p: own, listeners=lambda port: listening)

    def test_listener_inspection_is_bounded_read_only_and_rejects_unsafe_values(self):
        calls = []
        def runner(args, **kwargs):
            calls.append((args, kwargs))
            return SimpleNamespace(returncode=0, stdout='[9]')
        self.assertEqual(listener_process_ids(19642, runner=runner), {9})
        self.assertEqual(calls[0][1]['timeout'], 20)
        self.assertIn('Get-NetTCPConnection', calls[0][0][-1])
        self.assertNotIn('Stop-Process', calls[0][0][-1])
        for port in [9223, 9234, True, '19642; Stop-Process', 0]:
            with self.subTest(port=port), self.assertRaisesRegex(RuntimeError, 'PORT_INVALID'):
                listener_process_ids(port, runner=runner)
        for data in ['{"PID":9}', '[true]', 'not-json']:
            with self.subTest(data=data), self.assertRaisesRegex(RuntimeError, 'OWNER_INSPECTION_FAILED'):
                listener_process_ids(19642, runner=lambda *args, **kw: SimpleNamespace(returncode=0, stdout=data))

    def bare(self, profile, calls, *, pw_fail=False, hider_fail=False, process=None, profile_owned=True):
        browser = object.__new__(ChromeJob)
        browser.profile = profile
        browser.port = 19642
        browser.profile_owned = profile_owned
        browser.cleanup_verified = False
        browser.find = lambda path: {9}
        def cdp_send(command): calls.append(command)
        browser.browser = SimpleNamespace(new_browser_cdp_session=lambda: SimpleNamespace(send=cdp_send),
                                           close=lambda: calls.append('browser_close'))
        def stop_pw():
            calls.append('pw_stop')
            if pw_fail: raise RuntimeError('driver fault')
        def stop_hider():
            calls.append('hider_stop')
            if hider_fail: raise RuntimeError('hider fault')
        browser.pw, browser.hider = SimpleNamespace(stop=stop_pw), SimpleNamespace(stop=stop_hider)
        browser.process = process or SimpleNamespace(wait=lambda timeout: calls.append('process_wait'))
        return browser

    def test_driver_or_hider_failure_does_not_skip_owned_process_cleanup(self):
        for fault in ('pw_fail', 'hider_fail'):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as tmp:
                profile = Path(tmp) / 'owned'; profile.mkdir()
                calls = []
                browser = self.bare(profile, calls, **{fault: True})
                def cleanup(find): calls.append('exact_cleanup'); return {'closed': True}
                with patch('v2.ttittulares.editorial_browser_v2.verify_endpoint_owned', return_value=True), \
                     patch('v2.ttittulares.editorial_browser_v2.common', return_value=SimpleNamespace(cleanup_v2_profile=cleanup)):
                    with self.assertRaisesRegex(RuntimeError, 'RESOURCE_CLOSE_FAILED'):
                        browser.close()
                self.assertIn('exact_cleanup', calls)
                self.assertTrue(browser.cleanup_verified)
                self.assertFalse(profile.exists())

    def test_replaced_endpoint_is_never_sent_browser_close(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            profile = Path(tmp) / 'own'; profile.mkdir()
            browser = self.bare(profile, calls)
            def cleanup(find): calls.append('exact_cleanup'); return {'closed': True}
            with patch('v2.ttittulares.editorial_browser_v2.verify_endpoint_owned', side_effect=RuntimeError('foreign endpoint')), \
                 patch('v2.ttittulares.editorial_browser_v2.common', return_value=SimpleNamespace(cleanup_v2_profile=cleanup)):
                browser.close()
            self.assertNotIn('Browser.close', calls)
            self.assertNotIn('browser_close', calls)
            self.assertIn('exact_cleanup', calls)

    def test_cleanup_failure_preserves_profile_credentials_for_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            profile = Path(tmp) / 'own'; profile.mkdir()
            browser = self.bare(profile, calls)
            with patch('v2.ttittulares.editorial_browser_v2.verify_endpoint_owned', return_value=True), \
                 patch('v2.ttittulares.editorial_browser_v2.common', return_value=SimpleNamespace(cleanup_v2_profile=lambda find: {'closed': False})):
                with self.assertRaisesRegex(RuntimeError, 'CLEANUP_UNVERIFIED'):
                    browser.close()
            self.assertTrue(profile.exists())

    def test_rejected_existing_profile_is_never_deleted_by_close(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp) / 'preexisting'; profile.mkdir()
            browser = self.bare(profile, [], profile_owned=False)
            browser.process = browser.browser = browser.pw = browser.hider = None
            browser.close()
            self.assertTrue(profile.exists())


    def test_localized_user_transcript_confirms_exact_identity_when_role_dom_is_absent(self):
        for user_label, assistant_label in [('You said:', 'ChatGPT said:'),
                                             ('Tú dijiste:', 'ChatGPT dijo:'),
                                             ('Has dicho:', 'ChatGPT respondió:')]:
            clock = Clock()
            page = TranscriptPage(clock, '\n' + user_label + '\n' + USER + '\n' +
                                  assistant_label + '\n' + ANSWER)
            self.assertEqual(self.confirm(page, clock), page.url)
            self.assertEqual(self.capture(page, clock), (ANSWER, page.url))

    def test_assistant_echo_or_multiple_user_turns_cannot_confirm_fallback(self):
        for body in ['ChatGPT said:\n' + USER,
                     '\nYou said:\n' + USER + '\nYou said:\n' + USER + '\nChatGPT said:\n' + ANSWER,
                     '\nYou said:\nwrong command\nChatGPT said:\n' + USER]:
            clock = Clock()
            with self.assertRaisesRegex(RuntimeError, 'SUBMISSION_UNCONFIRMED'):
                self.confirm(TranscriptPage(clock, body), clock, timeout=6)

    def test_confirmation_can_select_another_owned_page_without_sending(self):
        clock, selected, observed = Clock(), [], []
        original = Page(clock, users=lambda _: [], url=lambda _: 'https://chatgpt.com/')
        target = Page(clock)
        url = confirm_user_turn(original, event_id=EVENT, revision=REVISION,
            command_id=COMMAND, heartbeat=lambda: None, clock=clock, sleep=clock.sleep,
            pages=lambda: [original, target], on_match=selected.append, on_observation=observed.append)
        self.assertEqual(url, target.url)
        self.assertEqual(selected, [target])
        self.assertTrue(any(row.get('exact_identity') for row in observed[-1]['targets']))

    def test_two_distinct_matching_conversations_are_quarantined(self):
        clock = Clock()
        one = Page(clock, url=lambda _: 'https://chatgpt.com/c/one')
        two = Page(clock, url=lambda _: 'https://chatgpt.com/c/two')
        with self.assertRaisesRegex(RuntimeError, 'MULTIPLE_MATCHING_CHATS'):
            confirm_user_turn(one, event_id=EVENT, revision=REVISION,
                command_id=COMMAND, heartbeat=lambda: None, clock=clock, sleep=clock.sleep,
                pages=lambda: [two])

    def test_ambiguous_submission_discards_owned_profile_after_verified_shutdown(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp) / 'own'; profile.mkdir()
            (profile / 'private-evidence').write_text('local only', encoding='utf-8')
            calls = []
            browser = self.bare(profile, calls)
            with patch('v2.ttittulares.editorial_browser_v2.verify_endpoint_owned', return_value=True), \
                 patch('v2.ttittulares.editorial_browser_v2.common', return_value=SimpleNamespace(
                     cleanup_v2_profile=lambda find: {'closed': True})):
                browser.close()
            self.assertTrue(browser.cleanup_verified)
            self.assertFalse(profile.exists())
            self.assertIn('process_wait', calls)



if __name__ == '__main__': unittest.main()
