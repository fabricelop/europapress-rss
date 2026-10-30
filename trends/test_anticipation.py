import copy
import threading
import unittest
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from datetime import datetime, timedelta, timezone
from trends import anticipation as a
from trends import update_trends
from trends.reconcile_prepared_ready import reconcile_prepared_ready


class AnticipationTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 30, 15, tzinfo=timezone.utc)
        self.requests = {'requests': []}
        self.manual = {'items': []}
        self.decisions = {'items': []}
        self.recent = {'captured_at': self.now.isoformat(), 'selection_method': 'fresh-anchor',
                       'items': [], 'upcoming': [], 'sources': {}}
        self.signal('Candidata')

    def signal(self, name):
        self.recent['upcoming'].append(dict(name=name, first_detected_at=(self.now-timedelta(minutes=10)).isoformat(),
            movement='up', social_sources=['fast', 'other'], best_observed_rank=32,
            rank_history=[dict(captured_at=(self.now-timedelta(minutes=10)).isoformat(), best_rank=48, source_count=1),
                          dict(captured_at=self.now.isoformat(), best_rank=32, source_count=2)]))
        for provider in ['fast', 'other']:
            self.recent['sources'].setdefault(provider, dict(ok=True, freshness='fresh', age_minutes=3,
                trends=[provider+' topic '+str(i) for i in range(20)]))['trends'].append(name)

    def sync(self, now=None):
        return a.sync(self.recent, self.requests, self.manual, self.decisions, now or self.now)

    def prepared(self):
        self.sync()
        job = self.requests['requests'][0]
        result = dict(job_id=job['id'], revision=0, outcome='prepared', reason='Hecho contrastado',
            explanation_body='Candidata es tendencia por un anuncio confirmado.\n#Anuncio #Candidata', closer_text='',
            verification_sources=[{'url': 'https://example.org/comunicado'}])
        self.requests, _ = a.apply_result(self.requests, result, self.now+timedelta(minutes=2))
        return result

    def test_two_slots_and_two_per_window_with_idempotent_selection(self):
        self.signal('Segunda'); self.signal('Tercera')
        metrics = self.sync()
        self.assertEqual(len(self.requests['requests']), 2)
        self.assertEqual(metrics['budget_eur'], 0)
        self.sync(); self.assertEqual(len(self.requests['requests']), 2)
        for job in self.requests['requests']:
            self.assertFalse(job['with_image'])
            self.assertTrue(job['disable_ai_image'])
            self.assertEqual(job['rank'], 0)
            self.assertTrue(job['name'].startswith('Radar · '))
            job['status'] = 'anticipation_unverified'
        self.sync(self.now+timedelta(minutes=5))
        self.assertEqual(len(self.requests['requests']), 2)
        self.sync(self.now+timedelta(minutes=15))
        self.assertEqual(len(self.requests['requests']), 3)

    def test_stale_unconfirmed_duplicate_source_or_flat_signals_cannot_enqueue(self):
        for case in ['stale_capture', 'old_signal', 'echo', 'unknown_freshness', 'flat', 'one_observation', 'one_source', 'top30']:
            with self.subTest(case=case):
                recent = copy.deepcopy(self.recent)
                if case == 'stale_capture': recent['captured_at'] = (self.now-timedelta(hours=2)).isoformat()
                if case == 'old_signal': recent['upcoming'][0]['first_detected_at'] = (self.now-timedelta(hours=2)).isoformat()
                if case == 'echo': recent['sources']['other']['trends'] = recent['sources']['fast']['trends'][:]
                if case == 'unknown_freshness':
                    for source in recent['sources'].values(): source.update(freshness='unknown', age_minutes=None)
                if case == 'flat': recent['upcoming'][0]['movement'] = 'flat'
                if case == 'one_observation': recent['upcoming'][0]['rank_history'] = recent['upcoming'][0]['rank_history'][-1:]
                if case == 'one_source': recent['upcoming'][0]['social_sources'] = ['fast']
                if case == 'top30': recent['items'] = [{'name': 'Candidata', 'rank': 29}]
                self.assertEqual(a.strong_signals(recent, self.now), [])

    def test_manual_pending_work_and_terminal_names_take_priority(self):
        for kind in ['manual', 'deleted', 'published', 'already_explained']:
            with self.subTest(kind=kind):
                reqs = {'requests': []}; manual = {'items': []}; decisions = {'items': []}
                if kind == 'manual': reqs['requests'].append(dict(id='manual', name='Otra', status='update'))
                elif kind == 'already_explained': manual['items'].append(dict(id='old', name='Grupo', trend_names=['Candidata'], status='explained'))
                else: decisions['items'].append(dict(id='closed', name='Candidata', status=kind))
                a.sync(self.recent, reqs, manual, decisions, self.now)
                self.assertFalse(any(x.get('anticipation_request') for x in reqs['requests']))

    def test_prepared_draft_has_no_publication_or_manual_ledger_side_effect(self):
        result = self.prepared()
        job = self.requests['requests'][0]
        self.assertEqual(job['status'], 'anticipation_prepared')
        self.assertEqual(self.manual, {'items': []})
        self.assertEqual(self.decisions, {'items': []})
        self.assertEqual(a.apply_result(self.requests, result, self.now), (self.requests, False))

    def test_top30_entry_reuses_fresh_draft_and_measures_preparation_lead(self):
        self.prepared()
        self.recent['items'] = [{'name': 'Candidata', 'rank': 27}]
        self.recent['captured_at'] = (self.now+timedelta(minutes=20)).isoformat()
        self.requests['requests'].append(dict(id='actual', name='Candidata', status='preparing', auto_queued=True, revision=0, rank=27))
        metrics = self.sync(self.now+timedelta(minutes=20))
        job, target = self.requests['requests']
        self.assertEqual(job['status'], 'anticipation_promoted')
        self.assertEqual(target['anticipation_draft'], job['anticipation_draft'])
        self.assertEqual(target['revision'], 0)
        self.assertEqual(metrics['prepared_before_top30'], 1)
        self.assertEqual(metrics['mean_preparation_lead_minutes'], 18)
        self.sync(self.now+timedelta(minutes=21))
        self.assertEqual(target['rewrite_instruction'].count('Ha entrado en Top 30'), 1)
        self.assertEqual(len(self.requests['requests']), 2)

    def test_promotion_never_overwrites_manual_or_closed_normal_request(self):
        for status, auto in [('update', False), ('published', True), ('deleted', True)]:
            self.setUp(); self.prepared()
            target = dict(id='normal', name='Candidata', status=status, auto_queued=auto, rewrite_instruction='Pistas originales')
            self.requests['requests'].append(target)
            self.recent['items'] = [{'name': 'Candidata', 'rank': 8}]
            before = copy.deepcopy(target)
            self.sync(self.now+timedelta(minutes=5))
            self.assertEqual(target, before)
            self.assertEqual(self.requests['requests'][0]['status'], 'anticipation_superseded')

    def test_unfinished_draft_is_superseded_when_normal_top30_work_arrives(self):
        self.sync()
        self.recent['items'] = [{'name': 'Candidata', 'rank': 10}]
        self.requests['requests'].append(dict(id='normal', name='Candidata', status='preparing', auto_queued=True))
        self.sync(self.now+timedelta(minutes=5))
        self.assertEqual(self.requests['requests'][0]['status'], 'anticipation_superseded')

    def test_draft_expires_and_late_result_cannot_revive_it(self):
        self.sync()
        self.sync(self.now+timedelta(minutes=61))
        job = self.requests['requests'][0]
        self.assertEqual(job['status'], 'anticipation_expired')
        self.assertEqual(a.apply_result(self.requests, dict(job_id=job['id']), self.now+timedelta(minutes=62)), (self.requests, False))

    def test_top30_entry_after_expiry_does_not_reuse_or_count_stale_preparation(self):
        self.prepared()
        entered = self.now+timedelta(minutes=61)
        self.recent.update(captured_at=entered.isoformat(), items=[{'name': 'Candidata', 'rank': 12}])
        self.requests['requests'].append(dict(id='normal', name='Candidata', status='preparing', auto_queued=True))
        metrics = self.sync(entered)
        self.assertNotIn('anticipation_draft', self.requests['requests'][-1])
        self.assertEqual(metrics['prepared_before_top30'], 0)
        self.assertIsNone(metrics['mean_preparation_lead_minutes'])

    def test_result_requires_current_revision_sources_and_short_unranked_body(self):
        result = self.prepared()
        for change in [dict(revision=2), dict(verification_sources=[]), dict(explanation_body='TT#32 Candidata'),
                       dict(explanation_body='x'*280+'\n#Uno #Dos')]:
            self.setUp(); self.sync()
            before = copy.deepcopy(self.requests)
            with self.assertRaises(ValueError):
                a.apply_result(self.requests, {**result, **change}, self.now)
            self.assertEqual(self.requests, before)

    def test_legacy_ready_cannot_promote_a_radar_job_to_listas(self):
        self.sync()
        req = self.requests['requests'][0]; req.update(status='ready', requested_at=self.now.isoformat())
        prepared = {'items': [dict(id=req['id'], revision=0, generated_at=self.now.isoformat(), explanation='TT#0 Candidata') ]}
        self.assertEqual(reconcile_prepared_ready(self.requests, prepared, self.manual, self.now.isoformat()), 0)
        self.assertEqual(self.manual['items'], [])

    def test_queue_producer_carries_draft_through_real_top30_promotion(self):
        self.now = datetime.now(timezone.utc)
        self.recent.update(captured_at=self.now.isoformat(), primary_source='fast', upcoming=[])
        self.signal('Candidata')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ['auto_queue_new.py', 'anticipation.py', 'reconcile_prepared_ready.py']:
                shutil.copy2(Path(__file__).with_name(name), root/name)
            def write(name, value): (root/name).write_text(json.dumps(value))
            def read(name): return json.loads((root/name).read_text())
            def tick():
                result = subprocess.run([sys.executable, str(root/'auto_queue_new.py')], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            write('recent.json', self.recent)
            write('requests.json', {'requests': []})
            write('telegram-manual-explained.json', {'items': []})
            tick()
            request = read('requests.json')
            job = request['requests'][0]
            queue = read('editorial-queue.json')['items']
            self.assertEqual(len(queue), 1)
            self.assertTrue(queue[0]['anticipation_request'])
            self.assertEqual(queue[0]['anticipation_signal']['name'], 'Candidata')
            now = datetime.now(timezone.utc)
            request, _ = a.apply_result(request, dict(job_id=job['id'], revision=0, outcome='prepared',
                reason='Verificado', explanation_body='Candidata es tendencia por un anuncio.\n#Anuncio #Candidata',
                verification_sources=[{'url': 'https://example.org/fuente'}]), now)
            write('requests.json', request)
            self.recent.update(captured_at=now.isoformat(), items=[{'name': 'Candidata', 'rank': 27}])
            write('recent.json', self.recent)
            tick()
            queue = read('editorial-queue.json')['items']
            self.assertEqual(len(queue), 1)
            self.assertFalse(queue[0]['anticipation_request'])
            self.assertEqual(queue[0]['rank'], 27)
            self.assertEqual(queue[0]['anticipation_origin_id'], job['id'])
            self.assertIn('explanation_body', queue[0]['anticipation_draft'])
            self.assertEqual(read('telegram-manual-explained.json')['items'], [])
            self.assertEqual(read('anticipation-metrics.json')['prepared_before_top30'], 1)


class SourceConcurrencyTests(unittest.TestCase):
    def test_four_parallel_workers_preserve_source_order_without_extra_requests(self):
        lock = threading.Lock(); barrier = threading.Barrier(4)
        active = 0; maximum = 0; calls = []
        def fetch(name):
            nonlocal active, maximum
            with lock:
                calls.append(name); number = len(calls)
                active += 1; maximum = max(maximum, active)
            if number <= 4: barrier.wait(timeout=3)
            with lock: active -= 1
            return {'source': name}
        result = update_trends.fetch_sources(fetch)
        self.assertEqual(list(result), list(update_trends.SOURCES))
        self.assertEqual(sorted(calls), sorted(update_trends.SOURCES))
        self.assertEqual(maximum, 4)
        self.assertTrue(all(result[name]['source'] == name for name in result))


if __name__ == '__main__':
    unittest.main()
