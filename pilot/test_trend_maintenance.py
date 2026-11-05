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

    def test_only_fresh_top30_and_no_hourly_duplicate(self):
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

    def colors(self):
        self.state[g.MANUAL]['items'] = []
        self.state[g.REQUESTS]['requests'] = []
        self.state[m.RECENT]['items'] = []
        for ident, hours in [('green', 2), ('yellow', 12), ('red', 25)]:
            self.add({**self.row, 'id': ident, 'name': ident,
                      'explained_at': (self.now-timedelta(hours=hours)).isoformat()})
            self.state[m.RECENT]['items'].append({'name': ident, 'rank': 2})

    def review_jobs(self):
        return [x for x in self.state[g.REQUESTS]['requests'] if x.get('red_review_request')]

    def test_priority_red_then_yellow_then_green_with_two_per_period(self):
        self.colors()
        m.schedule_reviews(self.state, self.now, g.grouping_api())
        jobs = self.review_jobs()
        self.assertEqual([x['review_source']['id'] for x in jobs], ['red', 'yellow'])
        self.assertEqual([x['review_color'] for x in jobs], ['roja', 'amarilla'])

    def test_completed_batch_does_not_refill_before_fifteen_minutes(self):
        self.colors()
        m.schedule_reviews(self.state, self.now, g.grouping_api())
        for job in self.review_jobs():
            command = dict(job_id=job['id'], outcome='unchanged', reason='Sin cambios comprobados',
                           verification_sources=[{'url': 'https://example.org/fuente'}])
            self.state, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        for minutes in [1, 5, 14]:
            m.schedule_reviews(self.state, self.now+timedelta(minutes=minutes), g.grouping_api())
            self.assertEqual(len(self.review_jobs()), 2)
        m.schedule_reviews(self.state, self.now+timedelta(minutes=15), g.grouping_api())
        self.assertEqual([x['review_source']['id'] for x in self.review_jobs()], ['red', 'yellow', 'green'])

    def test_active_reviews_occupy_slots_even_in_a_later_period(self):
        self.colors()
        m.schedule_reviews(self.state, self.now, g.grouping_api())
        m.schedule_reviews(self.state, self.now+timedelta(minutes=30), g.grouping_api())
        self.assertEqual(len(self.review_jobs()), 2)

    def test_green_can_receive_verified_update_without_waiting_to_turn_red(self):
        for path, field in [(g.MANUAL, 'items'), (g.REQUESTS, 'requests')]:
            self.state[path][field][0]['explained_at'] = (self.now-timedelta(hours=1)).isoformat()
        command = self.result('updated')
        command.update(explanation='TT#30 Adif sigue siendo tendencia por el anuncio de su rueda de prensa.\n#Adif #Trenes',
                       new_facts='Anuncio verificado durante una nueva rueda de prensa')
        state, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(state[g.REQUESTS]['requests'][-1]['review_color'], 'verde')
        self.assertEqual(state[g.REQUESTS]['requests'][-1]['review_outcome'], 'continuity')
        self.assertEqual(len(state[g.MANUAL]['items']), 1)
        self.assertEqual(state[g.MANUAL]['items'][0]['id'], 'a')
        self.assertEqual(state[g.MANUAL]['items'][0]['explanation'], self.row['explanation'])
        self.assertEqual(state[g.MANUAL]['items'][0]['red_review_outcome'], 'continuity')
        self.assertFalse(state[g.MANUAL]['items'][0].get('ai_image_status') == 'pending')

    def test_manual_rework_precedes_automatic_reviews_of_every_color(self):
        self.colors()
        self.state[g.REQUESTS]['requests'].append(dict(id='manual', revision=2, status='update',
                                                      name='Óscar Puente', auto_queued=False))
        self.schedule()
        self.assertFalse(self.review_jobs())

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
        command.update(explanation='TT#30 Adif es tendencia por otro cierre confirmado.\n#Adif #Trenes',
                       new_facts='Otro cierre confirmado hoy', closer_text='',
                       distinct_episode=True, material_change=True,
                       significance_reason='Nuevo cierre oficial con consecuencias propias',
                       material_event_key='adif-independent-official-closure-2026-10-30',
                       material_event_at=(self.now-timedelta(minutes=5)).isoformat())
        state, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(state[g.REQUESTS]['requests'][0]['status'], 'published')
        self.assertEqual(state[g.DECISIONS], self.state[g.DECISIONS])
        new = state[g.MANUAL]['items'][-1]
        self.assertNotEqual(new['id'], 'a')
        self.assertTrue(m.image_allowed(new))
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
        continuity, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(len(continuity[g.MANUAL]['items']), 1)
        self.assertEqual(continuity[g.REQUESTS]['requests'][-1]['review_outcome'], 'continuity')
        command['material_change'] = True
        command['significance_reason'] = 'Acontecimiento nuevo y sustancial comprobado'
        command['material_event_key'] = 'adif-independent-new-event-2026-10-30'
        command['material_event_at'] = (self.now-timedelta(minutes=5)).isoformat()
        final, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(len(final[g.MANUAL]['items']), 2)
        self.assertTrue(final[g.MANUAL]['items'][-1]['distinct_episode'])

    def test_same_episode_never_reenters_listas_or_regenerates_image(self):
        source = self.state[g.MANUAL]['items'][0]
        source.update(ai_image_status='ready', site_image_url='https://example.org/original.png')
        command = self.result('updated')
        command.update(explanation='TT#30 Adif sigue siendo tendencia por nuevas declaraciones.\\n#Adif',
                       new_facts='Declaraciones recientes verificadas',
                       material_change=True,
                       significance_reason='Interés informativo sin episodio independiente')
        final, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(len(final[g.MANUAL]['items']), 1)
        self.assertEqual(final[g.MANUAL]['items'][0]['ai_image_status'], 'ready')
        self.assertEqual(final[g.MANUAL]['items'][0]['site_image_url'], 'https://example.org/original.png')
        self.assertEqual(final[g.MANUAL]['items'][0]['explained_at'], self.row['explained_at'])
        self.assertEqual(len([row for row in final[g.REQUESTS]['requests']
                              if row.get('with_image') is True]), 0)

    def test_oscar_puente_resignation_review_cannot_create_duplicate_image(self):
        row = self.state[g.MANUAL]['items'][0]
        row.update(name='Óscar Puente',
                   explanation='TT#16 Óscar Puente es tendencia por su dimisión como ministro de Transportes.',
                   ai_image_status='ready',
                   site_image_url='https://example.org/original.png')
        self.state[g.REQUESTS]['requests'][0].update(row)
        self.state[m.RECENT]['items'] = [{'name': 'Óscar Puente', 'rank': 16}]
        job = self.schedule()[0]
        command = dict(job_id=job['id'], outcome='updated',
                       reason='Seguimiento de la misma dimisión sin hechos nuevos',
                       verification_sources=[{'url': 'https://example.org/source'}],
                       explanation='TT#16 Óscar Puente es tendencia por su dimisión como ministro de Transportes.',
                       new_facts='Óscar Puente dimite como ministro de Transportes',
                       distinct_episode=True, material_change=True,
                       significance_reason='La dimisión sigue en la agenda pero no es otro episodio',
                       material_event_key='oscar-puente-resignation-2026',
                       material_event_at=(self.now-timedelta(hours=26)).isoformat())
        result, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(len(result[g.MANUAL]['items']), 1)
        self.assertEqual(result[g.REQUESTS]['requests'][-1]['review_outcome'], 'continuity')
        self.assertEqual(result[g.MANUAL]['items'][0]['ai_image_status'], 'ready')
        self.assertEqual(result[g.MANUAL]['items'][0]['site_image_url'],
                         'https://example.org/original.png')

    def test_distinct_episode_needs_date_and_cannot_reuse_event_key(self):
        command = self.result('updated')
        command.update(explanation='TT#30 Adif es tendencia por otro corte internacional.',
                       new_facts='Nuevo corte internacional verificado en otra línea',
                       distinct_episode=True, material_change=True,
                       significance_reason='Se trata de otro suceso con consecuencias propias')
        first, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(len(first[g.MANUAL]['items']), 1)
        command['material_event_key'] = 'adif-international-second-cut-2026-10-30'
        command['material_event_at'] = (self.now-timedelta(minutes=5)).isoformat()
        new_state, _ = m.apply_review(self.state, command, self.now, g.grouping_api())
        self.assertEqual(len(new_state[g.MANUAL]['items']), 2)
        self.assertTrue(new_state[g.MANUAL]['items'][-1]['material_change_verified'])
        self.assertFalse(m.verified_distinct_material_event(
            command, self.row, new_state, self.now, g.grouping_api()))

    def test_new_work_does_not_trigger_automatic_grouping(self):
        fresh = {**self.row, 'id': 'b', 'name': 'Atocha',
                 'explained_at': self.now.isoformat()}
        self.add(fresh)
        self.state[g.REQUESTS]['requests'].append(
            dict(id='new', revision=0, status='preparing'))
        self.assertFalse(self.schedule())
        self.assertTrue(m.image_allowed(self.state[g.MANUAL]['items'][1]))
        self.state[g.REQUESTS]['requests'][-1]['status'] = 'explained'
        self.schedule()
        self.assertFalse(any(x.get('automatic_grouping')
                             for x in self.state[g.REQUESTS]['requests']))
        self.assertTrue(m.image_allowed(self.state[g.MANUAL]['items'][1]))

    def test_manual_grouping_is_retired_without_mutating_editorial_cards(self):
        self.add({**self.row, 'id': 'b', 'name': 'Atocha'})
        p = dict(project='ttendencias', decision='group_listas', request_id='12345678-1234-4234-8234-123456789abc',
                 items=[dict(id='a', revision=1), dict(id='b', revision=1)])
        before = copy.deepcopy(self.state)
        final, _ = g.request(self.state, p, self.now)
        self.assertFalse(final[g.QUEUE]['items'])
        self.assertEqual(final[g.RECEIPTS]['items'][-1]['status'], 'rejected')
        self.assertEqual(final[g.RECEIPTS]['items'][-1]['code'], 'TREND_GROUPING_RETIRED')
        for path in (g.MANUAL, g.REQUESTS, g.DECISIONS, g.DELIVERIES):
            self.assertEqual(final[path], before[path])

    def test_new_hashtag_is_not_automatically_covered_by_published_story(self):
        self.state[g.REQUESTS]['requests'][0]['status'] = 'published'
        self.state[g.DECISIONS]['items'] = [
            dict(id='a', revision=1, status='published',
                 updated_at=self.now.isoformat())]
        self.add({**self.row, 'id': 'b', 'name': 'Atocha',
                  'explained_at': self.now.isoformat()})
        self.schedule()
        self.assertFalse(any(x.get('automatic_grouping')
                             for x in self.state[g.REQUESTS]['requests']))
        row = self.state[g.MANUAL]['items'][1]
        self.assertFalse(row.get('covered_by_id'))
        self.assertTrue(m.image_allowed(row))
        self.assertEqual(len(self.state[g.MANUAL]['items']), 2)


if __name__ == '__main__':
    unittest.main()

