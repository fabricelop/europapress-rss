import copy
import unittest
from datetime import datetime, timedelta, timezone
from pilot import listas_grouping as g
from pilot import trend_maintenance as m


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 30, 12, tzinfo=timezone.utc)
        self.state = {p: {'items': []} for p in [g.MANUAL, g.QUEUE, g.DECISIONS, g.DELIVERIES, g.RECEIPTS]}
        self.state[g.REQUESTS] = {'requests': []}
        self.state[m.RECENT] = {'updated_at': self.now.isoformat(), 'items': [{'name': 'Adif', 'rank': 30}]}
        self.row = dict(id='a', revision=1, name='Adif', rank=30, status='explained',
                        explanation='TT#30 Adif es tendencia por el corte de trenes.\n#Adif #Trenes',
                        closer_text='', explained_at=(self.now-timedelta(hours=25)).isoformat())
        self.add(self.row)

    def add(self, row):
        for p, field in [(g.MANUAL, 'items'), (g.REQUESTS, 'requests')]:
            self.state[p][field].append(copy.deepcopy(row))

    def schedule(self):
        m.schedule(self.state, self.now, g.grouping_api())
        return [x for x in self.state[g.REQUESTS]['requests'] if x.get('red_review_request')]

    def result(self, outcome='unchanged'):
        job = self.schedule()[0]
        return dict(job_id=job['id'], outcome=outcome, reason='Comprobación de los hechos actuales',
                    verification_sources=[{'url': 'https://example.org/comunicado'}])

    def test_only_fresh_top30_reds_and_no_hourly_duplicate(self):
        self.assertEqual(len(self.schedule()), 1)
        self.assertEqual(len(self.schedule()), 1)
        for changes in [{'items': [{'name': 'Adif', 'rank': 31}]},
                        {'updated_at': (self.now-timedelta(hours=2)).isoformat()},
                        {'safe_to_auto_queue': False}]:
            with self.subTest(changes=changes):
                s = copy.deepcopy(self.state)
                s[g.REQUESTS]['requests'] = [s[g.REQUESTS]['requests'][0]]
                s[g.QUEUE]['items'] = []
                s[m.RECENT].update(changes)
                m.schedule_reviews(s, self.now, g.grouping_api())
                self.assertFalse(any(x.get('red_review_request') for x in s[g.QUEUE]['items']))

    def test_unchanged_preserves_text_date_and_color_age(self):
        command = self.result()
        state, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        row = state[g.MANUAL]['items'][0]
        self.assertEqual(row['explanation'], self.row['explanation'])
        self.assertEqual(row['explained_at'], self.row['explained_at'])
        self.assertEqual(row['red_review_outcome'], 'unchanged')
        self.assertEqual(len(state[g.MANUAL]['items']), 1)
        m.schedule_reviews(state, self.now+timedelta(minutes=59), g.grouping_api())
        self.assertFalse(any(x.get('red_review_request') for x in state[g.QUEUE]['items']))

    def test_published_source_stays_terminal_update_is_new_identity(self):
        self.state[g.REQUESTS]['requests'][0]['status'] = 'published'
        self.state[g.DECISIONS]['items'] = [dict(id='a', revision=1, status='published', updated_at=self.now.isoformat())]
        command = self.result('updated')
        command.update(explanation='TT#30 Adif sigue siendo tendencia por otro cierre confirmado.\n#Adif #Trenes',
                       new_facts='Otro cierre confirmado hoy', closer_text='')
        state, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(state[g.REQUESTS]['requests'][0]['status'], 'published')
        self.assertEqual(state[g.DECISIONS], self.state[g.DECISIONS])
        new = state[g.MANUAL]['items'][-1]
        self.assertNotEqual(new['id'], 'a')
        self.assertFalse(m.image_allowed(new))
        self.assertEqual(new['originated_from_prior_id'], 'a')
        self.assertEqual(m.apply_review(state, command, self.now, g.grouping_api()), (state, False))

    def test_deleted_reworked_or_text_changed_during_review_cannot_reappear(self):
        command = self.result('updated')
        command.update(explanation='TT#30 Adif sigue siendo tendencia por un cierre.\n#Adif #Trenes', new_facts='Un cierre nuevo')
        for change in ['deleted', 'revision', 'text', 'source_deleted', 'left_top30', 'superseded']:
            s = copy.deepcopy(self.state)
            if change == 'deleted':
                s[g.DECISIONS]['items'] = [dict(id='a', revision=1, status='deleted', updated_at=self.now.isoformat())]
            if change == 'revision':
                s[g.REQUESTS]['requests'][0].update(revision=2, status='preparing')
            if change == 'text':
                s[g.MANUAL]['items'][0]['explanation'] += ' cambiado'
            if change == 'source_deleted':
                s[g.MANUAL]['items'][0]['status'] = 'deleted'
            if change == 'left_top30':
                s[m.RECENT]['items'] = []
            if change == 'superseded':
                s[g.MANUAL]['items'].append({**self.row, 'id': 'newer', 'explained_at': self.now.isoformat()})
            final, _ = m.apply_review(s, command, self.now, g.grouping_api())
            self.assertEqual(len(final[g.MANUAL]['items']), len(s[g.MANUAL]['items']))
            self.assertEqual(final[g.REQUESTS]['requests'][-1]['review_outcome'], 'stale')

    def test_unverified_preserves_explanation_with_visible_reason(self):
        command = self.result('unverified')
        command['verification_sources'] = []
        final, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(final[g.MANUAL]['items'][0]['explanation'], self.row['explanation'])
        self.assertEqual(final[g.MANUAL]['items'][0]['red_review_outcome'], 'unverified')

    def test_updates_require_new_facts_sources_and_continuity_prefix(self):
        command = self.result('updated')
        command.update(explanation='TT#30 Adif es tendencia por un cierre.', new_facts='Cierre')
        with self.assertRaises(ValueError):
            m.apply_review(self.state, command, self.now, g.grouping_api())
        command['distinct_episode'] = True
        final, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertTrue(final[g.MANUAL]['items'][-1]['distinct_episode'])

    def test_new_work_precedes_maintenance_and_images_wait_for_grouping(self):
        fresh = {**self.row, 'id': 'b', 'name': 'Atocha', 'explained_at': self.now.isoformat()}
        self.add(fresh)
        self.state[g.REQUESTS]['requests'].append(dict(id='new', revision=0, status='preparing'))
        self.assertFalse(self.schedule())
        self.assertFalse(m.image_allowed(self.state[g.MANUAL]['items'][1]))
        self.state[g.REQUESTS]['requests'][-1]['status'] = 'explained'
        self.schedule()
        job = next(x for x in self.state[g.REQUESTS]['requests'] if x.get('automatic_grouping'))
        final, _ = g.apply_result(self.state, dict(job_id=job['id'], groups=[]), self.now)
        row = final[g.MANUAL]['items'][1]
        self.assertTrue(m.image_allowed(row))
        row['explanation'] += ' revisión técnica'
        self.assertFalse(m.image_allowed(row))

    def test_manual_selection_excludes_other_listas_and_rejects_stale(self):
        self.add({**self.row, 'id': 'b', 'name': 'Atocha'})
        self.add({**self.row, 'id': 'c', 'name': 'Copa'})
        p = dict(project='ttendencias', decision='group_listas', request_id='12345678-1234-4234-8234-123456789abc',
                 items=[dict(id='a', revision=1), dict(id='b', revision=1)])
        final, _ = g.request(self.state, p, self.now)
        self.assertEqual({x['id'] for x in final[g.QUEUE]['items'][-1]['grouping_candidates']}, {'a', 'b'})
        p['items'][1]['revision'] = 0
        final, _ = g.request(self.state, p, self.now)
        self.assertFalse(final[g.QUEUE]['items'])
        self.assertEqual(final[g.RECEIPTS]['items'][-1]['status'], 'rejected')

    def test_new_hashtag_can_be_covered_by_published_story_without_new_post(self):
        self.state[g.REQUESTS]['requests'][0]['status'] = 'published'
        self.state[g.DECISIONS]['items'] = [dict(id='a', revision=1, status='published', updated_at=self.now.isoformat())]
        self.add({**self.row, 'id': 'b', 'name': 'Atocha', 'explained_at': self.now.isoformat()})
        self.schedule()
        job = next(x for x in self.state[g.REQUESTS]['requests'] if x.get('automatic_grouping'))
        command = dict(job_id=job['id'], groups=[], covered_by_existing=[dict(
            member=dict(id='b', revision=1), published_id='a', no_material_changes=True, reason='Mismo corte ya publicado')])
        final, _ = g.apply_result(self.state, command, self.now)
        row = final[g.MANUAL]['items'][1]
        self.assertEqual(row['covered_by_id'], 'a')
        self.assertFalse(m.image_allowed(row))
        self.assertEqual(len(final[g.MANUAL]['items']), 2)


if __name__ == '__main__':
    unittest.main()
