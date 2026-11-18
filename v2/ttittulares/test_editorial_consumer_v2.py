import copy
import json
from contextlib import nullcontext
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from .editorial_browser_v2 import clone_job_profile, fresh_turn, write_private
from .editorial_consumer_v2 import run_one, enabled, error_code, preflight_once


class Service:
    def __init__(self, *, authorized=True, idle=False):
        self.calls = []
        self.authorized, self.idle = authorized, idle

    def claim(self, worker, token):
        self.calls.append('claim')
        if self.idle:
            return {'job': None}
        return {'job': {'job_id': 'job', 'event_id': 'event', 'revision': 1}, 'event': {}}

    def prepare_send(self, *args, **kwargs):
        self.calls.append('intent')
        return {'send_authorized': self.authorized}

    def submitted(self, *args, **kwargs):
        self.calls.append('submitted')
        return {'verified': True}
    def captured(self, *args, **kwargs):
        self.calls.append('captured')
        return {'verified': True}
    def heartbeat(self, *args): self.calls.append('heartbeat')
    def complete(self, *args):
        self.calls.append('complete')
        return {'verified': True, 'commit_sha': 'a' * 40}
    def fail(self, *args, **kwargs):
        self.calls.append(('fail', kwargs['safe_preflight']))
        return {'verified': True}


class Browser:
    def __init__(self, calls, fail=None):
        self.calls, self.fail, self.cleanup_verified = calls, fail, False
    def open(self):
        self.calls.append('open')
        if self.fail == 'open': raise RuntimeError('AUTH_NOT_READY')
    def send_once(self, prompt):
        self.calls.append('send')
        if self.fail == 'send': raise RuntimeError('ENTER_ACK_UNKNOWN')
    def capture(self, *args):
        self.calls.append('capture')
        if self.fail == 'capture': raise RuntimeError('PARTIAL_RESPONSE')
        return 'answer', 'https://chatgpt.com/c/private-chat'
    def confirm_submission(self, *args, **kwargs):
        self.calls.append('confirm')
        if self.fail == 'confirm': raise RuntimeError('TURN_NOT_CONFIRMED')
        return 'https://chatgpt.com/c/private-chat'
    def close(self):
        self.calls.append('close')
        if self.fail == 'close': raise RuntimeError('BROWSER_STILL_ACTIVE')
        self.cleanup_verified = True


class ConsumerTests(unittest.TestCase):
    def work(self, service=None, fail=None, parse_fail=False):
        service = service or Service()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        def parse(*args):
            if isinstance(parse_fail, Exception): raise parse_fail
            if parse_fail: raise ValueError('INVALID_EDITORIAL')
            return {'validated_record': True}
        result = run_one(service, {'root': root, 'chrome': root / 'chrome', 'seed': root / 'seed'},
                         browser_factory=lambda **kw: Browser(service.calls, fail),
                         build=lambda *args: 'prompt', parse=parse)
        return result, service.calls, root

    def test_one_send_intent_first_close_before_ready(self):
        result, calls, root = self.work()
        self.assertEqual(calls, ['claim', 'open', 'intent', 'send', 'confirm', 'submitted', 'capture', 'captured', 'close', 'complete'])
        self.assertEqual(result['status'], 'ready')
        self.assertFalse(result['published'])
        journal = json.loads(next((root / 'journals').glob('*.json')).read_text())
        self.assertTrue(journal['ready_verified'])
        self.assertTrue(journal['cleanup_verified'])

    def test_unknown_enter_never_retries_or_becomes_safe_preflight(self):
        result, calls, root = self.work(fail='send')
        self.assertEqual(calls.count('send'), 1)
        self.assertIn(('fail', False), calls)
        self.assertNotIn('complete', calls)
        self.assertEqual(result['status'], 'incident')
        journal = json.loads(next((root / 'journals').glob('*.json')).read_text())
        self.assertTrue(journal['intent_durable'])
        self.assertTrue(journal['cleanup_verified'])
        self.assertFalse(journal['sent'])

    def test_uncertain_send_does_not_request_to_keep_disposable_profile(self):
        service = Service()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            class BrowserWithGuard(Browser):
                def close(self):
                    self.calls.append(('preserved_at_close', getattr(self, 'preserve_profile', False)))
                    super().close()
            report = run_one(service, {'root': root, 'chrome': root / 'chrome', 'seed': root / 'seed'},
                browser_factory=lambda **kw: BrowserWithGuard(service.calls, fail='confirm'),
                build=lambda *a: 'prompt', parse=lambda *a: {})
            self.assertEqual(report['status'], 'incident')
            self.assertIn(('preserved_at_close', False), service.calls)
            self.assertEqual(service.calls.count('send'), 1)
            self.assertIn(('fail', False), service.calls)

    def test_daemon_does_not_claim_or_preview_if_startup_preflight_fails(self):
        from .editorial_consumer_v2 import daemon
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            flag = root / "editorial.enabled"
            flag.write_text("TTN2_EDITORIAL_ENABLED=YES")
            service = Service()
            class Lock:
                def exclusive_v2_lock(self, path):
                    return nullcontext()
            with patch("v2.ttittulares.editorial_consumer_v2.common", return_value=Lock()), \
                 patch("v2.ttittulares.editorial_consumer_v2.preflight_once",
                       return_value={"ok": False, "error_code": "NEWS_FRESH_CHAT_NOT_READY",
                                     "cleanup_verified": True, "stage": "COMPOSER_MISSING"}), \
                 patch("v2.ttittulares.session_watchdog_v2.reclaim_disposable_sessions",
                       return_value={"reclaimed": 0}), \
                 patch("v2.ttittulares.editorial_consumer_v2.time.sleep",
                       side_effect=lambda seconds: flag.write_text("TTN2_EDITORIAL_ENABLED=NO")):
                daemon(service, {"root": root, "chrome": root / "c",
                                 "seed": root / "s"}, poll=1)
            self.assertEqual(service.calls, [])
            health = json.loads((root / "editorial-daemon-health.json").read_text())
            self.assertEqual(health["state"], "WAIT_FRESH_CHAT_RETRY")
            self.assertEqual(health["error_code"], "NEWS_FRESH_CHAT_NOT_READY")
            self.assertFalse(health["claims_authorized"])

    def test_preflight_fresh_chat_failure_is_closed_and_does_not_claim(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls = []
            class FreshBrowser(Browser):
                def open(self):
                    self.calls.append("open")
                    raise RuntimeError("NEWS_FRESH_CHAT_NOT_READY")
            check = preflight_once({"root": root, "chrome": root / "c", "seed": root / "s"},
                browser_factory=lambda **kwargs: FreshBrowser(calls))
            self.assertEqual(check["error_code"], "NEWS_FRESH_CHAT_NOT_READY")
            self.assertFalse(check["ok"])
            self.assertTrue(check["cleanup_verified"])
            self.assertEqual(calls, ["open", "close"])
            self.assertFalse((root / "journals").exists())

    def test_preflight_recovery_can_pass_next_attempt_with_new_empty_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profiles = []
            outcomes = iter([False, True])
            class FreshBrowser(Browser):
                def open(self):
                    self.calls.append("open")
                    if not next(outcomes):
                        raise RuntimeError("NEWS_FRESH_CHAT_NOT_READY")
            def factory(**kwargs):
                profiles.append(kwargs["profile"])
                return FreshBrowser([])
            a = preflight_once({"root": root, "chrome": root / "c", "seed": root / "s"},
                               browser_factory=factory)
            b = preflight_once({"root": root, "chrome": root / "c", "seed": root / "s"},
                               browser_factory=factory)
            self.assertEqual((a["ok"], b["ok"]), (False, True))
            self.assertNotEqual(profiles[0], profiles[1])
            self.assertIsNone(b["error_code"])

    def test_preflight_unclean_browser_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            class UncleanBrowser(Browser):
                def open(self):
                    raise RuntimeError("NEWS_FRESH_CHAT_NOT_READY")
                def close(self):
                    raise RuntimeError("NEWS_OWN_CHROME_CLEANUP_UNVERIFIED")
            check = preflight_once({"root": root, "chrome": root / "c", "seed": root / "s"},
                browser_factory=lambda **kwargs: UncleanBrowser([]))
            self.assertFalse(check["ok"])
            self.assertFalse(check["cleanup_verified"])
            self.assertEqual(check["error_code"], "NEWS_OWN_CHROME_CLEANUP_UNVERIFIED")

    def test_preflight_failure_is_safe_without_send_intent(self):
        _, calls, root = self.work(fail='open')
        self.assertIn(('fail', True), calls)
        self.assertNotIn('send', calls)
        self.assertNotIn('intent', calls)

    def test_unknown_exception_text_cannot_leak_into_a_public_error_code(self):
        self.assertEqual(error_code(RuntimeError('NEWS_CHATGPT_AUTH_REQUIRED')), 'NEWS_CHATGPT_AUTH_REQUIRED')
        self.assertEqual(error_code(RuntimeError('https://private.example/token=secret')), 'RUNTIMEERROR')

    def test_transient_github_failure_before_claim_reports_prechat_incident_without_browser(self):
        class BrokenReadService(Service):
            def claim(self, worker, token):
                self.calls.append('claim')
                raise RuntimeError('NEWS_PINNED_BLOB_READ_UNAVAILABLE')
        report, calls, root = self.work(service=BrokenReadService())
        self.assertEqual(report['status'], 'incident')
        self.assertEqual(report['error_code'], 'NEWS_PINNED_BLOB_READ_UNAVAILABLE')
        self.assertTrue(report['pre_chat_failure'])
        self.assertEqual(calls, ['claim'])
        self.assertFalse((root / 'journals').exists())

    def test_global_auth_failure_pauses_new_claims_without_marking_news_bad(self):
        class AuthBrowser(Browser):
            def open(self):
                raise RuntimeError('NEWS_CHATGPT_AUTHENTICATED_ACCOUNT_REQUIRED')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'editorial.enabled').write_text('TTN2_EDITORIAL_ENABLED=YES')
            service = Service()
            report = run_one(service, {'root': root, 'chrome': root / 'c', 'seed': root / 's'},
                             browser_factory=lambda **kw: AuthBrowser(service.calls),
                             build=lambda *a: 'prompt', parse=lambda *a: {})
            self.assertFalse(enabled(root))
            self.assertIn(('fail', True), service.calls)
            self.assertEqual(report['error_code'], 'NEWS_CHATGPT_AUTHENTICATED_ACCOUNT_REQUIRED')

    def test_v1_style_pilot_accepts_only_never_attempted_fresh_jobs(self):
        from .pilot_one_v2 import safe_first_job
        fresh = {'status': 'pending', 'revision': 2,
                 'job_id': 'ttn2-' + 'a' * 24 + '-r2-editorial',
                 'attempts': {'claim_count': 0, 'submission_count': 0, 'history': []},
                 'lease': None, 'send_intent': None, 'session': None,
                 'capture': None, 'result': None, 'problem': None}
        self.assertTrue(safe_first_job(fresh))
        for change in ({'revision': 0}, {'status': 'problematic'},
                       {'send_intent': {'command_id': 'previous'}},
                       {'attempts': {'claim_count': 1}},
                       {'attempts': {'history': [{'sent': True}]}}):
            with self.subTest(change=change):
                self.assertFalse(safe_first_job({**fresh, **change}))

    def test_fresh_chat_preflight_failure_does_not_disable_entire_consumer(self):
        for code in ('NEWS_CHATGPT_AUTH_OR_FRESH_CHAT_REQUIRED',
                     'NEWS_FRESH_CHAT_NOT_READY', 'NEWS_CHATGPT_AUTH_CHECK_UNAVAILABLE'):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / 'editorial.enabled').write_text('TTN2_EDITORIAL_ENABLED=YES')
                service = Service()
                class FreshTabBrowser(Browser):
                    def open(self): raise RuntimeError(code)
                result = run_one(service, {'root': root, 'chrome': root / 'c', 'seed': root / 's'},
                    browser_factory=lambda **kw: FreshTabBrowser(service.calls),
                    build=lambda *a: 'prompt', parse=lambda *a: {})
                self.assertTrue(enabled(root))
                self.assertEqual(result['error_code'], code)
                self.assertIn(('fail', True), service.calls)
                self.assertNotIn('intent', service.calls)

    def test_commit_failure_preserves_capture_and_never_reports_ready(self):
        class FailingService(Service):
            def complete(self, *args): raise RuntimeError('COMMIT_UNCERTAIN')
        report, calls, root = self.work(service=FailingService())
        self.assertEqual(report['status'], 'incident')
        self.assertEqual(calls.count('send'), 1)
        saved = json.loads(next((root / 'journals').glob('*.json')).read_text())
        self.assertEqual(saved['answer'], 'answer')
        self.assertFalse(saved['ready_verified'])

    def test_enter_without_exact_user_turn_is_never_confirmed_or_resent(self):
        _, calls, _ = self.work(fail='confirm')
        self.assertEqual(calls.count('send'), 1)
        self.assertNotIn('submitted', calls)
        self.assertIn(('fail', False), calls)

    def test_replayed_intent_never_authorizes_an_enter(self):
        _, calls, _ = self.work(service=Service(authorized=False))
        self.assertNotIn('send', calls)
        self.assertIn(('fail', False), calls)

    def test_partial_invalid_or_unclean_result_cannot_become_ready(self):
        for stage in ('capture', 'close'):
            with self.subTest(stage=stage):
                result, calls, _ = self.work(fail=stage)
                self.assertEqual(result['status'], 'incident')
                self.assertNotIn('complete', calls)
        _, calls, _ = self.work(parse_fail=True)
        self.assertNotIn('complete', calls)
        self.assertIn(('fail', False), calls)

    def test_verified_validation_failure_is_quarantined_without_ready_or_another_send(self):
        from .editorial_contract_v2 import ContractError
        report, calls, root = self.work(parse_fail=ContractError('ESSENTIAL_FACT_NOT_VERIFIED'))
        self.assertEqual(report['status'], 'quarantined')
        for key in ('submission_confirmed', 'capture_complete', 'capture_persisted',
                    'failure_persisted', 'cleanup_verified'):
            self.assertTrue(report[key])
        self.assertFalse(report['published'])
        self.assertEqual(calls.count('send'), 1)
        self.assertNotIn('complete', calls)
        journal = json.loads(next((root / 'journals').glob('*.json')).read_text())
        self.assertEqual(journal['answer'], 'answer')

    def test_validation_rejection_does_not_pass_with_unverified_failure_persistence(self):
        from .editorial_contract_v2 import ContractError
        class FailingService(Service):
            def fail(self, *args, **kwargs): raise RuntimeError('COMMIT_UNCERTAIN')
        report, _, _ = self.work(service=FailingService(), parse_fail=ContractError('ESSENTIAL_FACT_NOT_VERIFIED'))
        self.assertEqual(report['status'], 'incident')
        self.assertFalse(report['failure_persisted'])

    def test_validation_rejection_requires_verified_capture_persistence(self):
        from .editorial_contract_v2 import ContractError
        class UnverifiedService(Service):
            def captured(self, *args, **kwargs): return {'verified': False}
        report, _, _ = self.work(service=UnverifiedService(), parse_fail=ContractError('ESSENTIAL_FACT_NOT_VERIFIED'))
        self.assertEqual(report['status'], 'incident')

    def test_validation_rejection_requires_confirmed_submission(self):
        from .editorial_contract_v2 import ContractError
        class UnverifiedService(Service):
            def submitted(self, *args, **kwargs): return {'verified': False}
        report, _, _ = self.work(service=UnverifiedService(), parse_fail=ContractError('ESSENTIAL_FACT_NOT_VERIFIED'))
        self.assertEqual(report['status'], 'incident')

    def test_validation_rejection_requires_verified_cleanup(self):
        from .editorial_contract_v2 import ContractError
        report, calls, _ = self.work(fail='close', parse_fail=ContractError('ESSENTIAL_FACT_NOT_VERIFIED'))
        self.assertEqual(report['status'], 'incident')
        self.assertNotIn('complete', calls)

    def test_unexpected_parser_failure_is_not_a_successful_quarantine_pilot(self):
        report, _, _ = self.work(parse_fail=True)
        self.assertEqual(report['status'], 'incident')

    def test_idle_does_not_open_browser(self):
        result, calls, _ = self.work(service=Service(idle=True))
        self.assertEqual(result['status'], 'idle')
        self.assertEqual(calls, ['claim'])

    def test_profile_copies_auth_without_sessions_and_never_reuses_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed, dest = Path(tmp) / 'seed', Path(tmp) / 'job'
            (seed / 'Default' / 'Sessions').mkdir(parents=True)
            (seed / 'Default' / 'Sessions' / 'old').write_text('not fresh')
            (seed / 'Local State').write_text('auth')
            clone_job_profile(seed, dest, find_pids=lambda p: [])
            self.assertEqual((dest / 'Local State').read_text(), 'auth')
            self.assertFalse((dest / 'Default' / 'Sessions').exists())
            with self.assertRaisesRegex(RuntimeError, 'ALREADY_EXISTS'):
                clone_job_profile(seed, dest, find_pids=lambda p: [])
            with self.assertRaisesRegex(RuntimeError, 'BROWSER_BUSY'):
                clone_job_profile(seed, Path(tmp) / 'other', find_pids=lambda p: [99])

    def test_profile_source_that_opens_during_copy_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed = Path(tmp) / 'seed'; seed.mkdir(); (seed / 'Local State').write_text('auth')
            destination = Path(tmp) / 'job'
            pids = iter([[], [88], []])
            with self.assertRaisesRegex(RuntimeError, 'CHANGED_DURING_COPY'):
                clone_job_profile(seed, destination, find_pids=lambda p: next(pids))
            self.assertFalse(destination.exists())

    def test_failed_profile_copy_cleans_own_partial_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed, destination = Path(tmp) / 'seed', Path(tmp) / 'job'
            seed.mkdir(); (seed / 'Local State').write_text('auth')
            def broken_copy(source, target, **kwargs):
                (target / 'incomplete').write_text('partial')
                raise OSError('DISK_FULL')
            with patch('v2.ttittulares.editorial_browser_v2.shutil.copytree', side_effect=broken_copy):
                with self.assertRaisesRegex(OSError, 'DISK_FULL'):
                    clone_job_profile(seed, destination, find_pids=lambda p: [])
            self.assertFalse(destination.exists())
            self.assertTrue((seed / 'Local State').exists())

    def test_low_disk_space_never_creates_a_new_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed, destination = Path(tmp) / 'seed', Path(tmp) / 'job'
            seed.mkdir(); (seed / 'Local State').write_text('auth')
            with patch('v2.ttittulares.editorial_browser_v2.shutil.disk_usage',
                       return_value=SimpleNamespace(free=1024)):
                with self.assertRaisesRegex(RuntimeError, 'DISK_SPACE_LOW'):
                    clone_job_profile(seed, destination, find_pids=lambda p: [])
            self.assertFalse(destination.exists())

    def test_message_identity_includes_exact_revision_and_single_user(self):
        good = ['{"event_id":"event", "revision": 1, "command_id":"command"}']
        self.assertTrue(fresh_turn(good, 'event', 1, 'command'))
        self.assertFalse(fresh_turn(good, 'event', 11, 'command'))
        self.assertFalse(fresh_turn(good * 2, 'event', 1, 'command'))
        self.assertFalse(fresh_turn(good, 'event', 1, 'other-command'))

    def test_flag_is_exact_and_private_journal_is_complete_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            self.assertFalse(enabled(path))
            (path / 'editorial.enabled').write_text('TTN2_EDITORIAL_ENABLED=YES')
            self.assertTrue(enabled(path))
            (path / 'editorial.enabled').write_text('YES')
            self.assertFalse(enabled(path))
            write_private(path / 'j.json', {'captured': True})
            self.assertEqual(json.loads((path / 'j.json').read_text()), {'captured': True})


if __name__ == '__main__': unittest.main()
