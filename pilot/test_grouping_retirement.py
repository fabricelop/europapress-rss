import copy
import unittest
from datetime import datetime, timezone
from pilot import listas_grouping as g
from pilot import trend_maintenance as maintenance


class GroupingRetirementTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 3, 18, tzinfo=timezone.utc)
        self.state = {p: {'items': []} for p in (g.MANUAL, g.QUEUE, g.DECISIONS, g.DELIVERIES, g.RECEIPTS)}
        self.state[g.REQUESTS] = {'requests': []}
        self.payload = dict(project='ttendencias', decision='group_listas',
                            request_id='12345678-1234-4234-8234-123456789abc',
                            items=[dict(id='a', revision=1), dict(id='b', revision=1)])

    def test_grouping_and_cleanup_fail_closed_with_idempotent_receipt(self):
        for decision in ('group_listas', 'remove_covered'):
            command = {**self.payload, 'decision': decision}
            final, changed = g.request(self.state, command, self.now)
            self.assertTrue(changed)
            self.assertEqual(final[g.RECEIPTS]['items'][0]['code'], 'TREND_GROUPING_RETIRED')
            self.assertEqual(final[g.RECEIPTS]['items'][0]['status'], 'rejected')
            self.assertEqual(g.request(final, command, self.now), (final, False))
            for path in (g.MANUAL, g.REQUESTS, g.QUEUE, g.DECISIONS, g.DELIVERIES):
                self.assertEqual(final[path], self.state[path])

    def test_retirement_preserves_snapshots_and_ordinary_review_and_terminal_jobs(self):
        job = dict(id='group-job', revision=0, status='preparing', listas_grouping_request=True,
                   grouping_candidates=[dict(id='a', revision=2, explanation='Original')])
        ordinary = dict(id='ordinary', revision=1, status='preparing')
        review = dict(id='review', revision=0, status='update', red_review_request=True)
        terminal = dict(id='finished', revision=0, status='grouping_completed', listas_grouping_request=True)
        rows = [job, ordinary, review, terminal]
        self.state[g.REQUESTS]['requests'] = copy.deepcopy(rows)
        self.state[g.QUEUE]['items'] = copy.deepcopy(rows[:3])
        self.state[g.MANUAL]['items'] = [dict(id='a', revision=2, explanation='Original', listas_group_role='covered', covered_by_id='joint')]
        final, changed = g.retire_pending_grouping(self.state, self.now)
        self.assertTrue(changed)
        retired = final[g.REQUESTS]['requests'][0]
        self.assertEqual(retired['status'], 'grouping_retired')
        self.assertEqual(retired['grouping_candidates'], job['grouping_candidates'])
        self.assertEqual(final[g.REQUESTS]['requests'][1:], rows[1:])
        self.assertEqual(final[g.QUEUE]['items'], [ordinary, review])
        self.assertEqual(final[g.MANUAL], self.state[g.MANUAL])
        self.assertEqual(g.retire_pending_grouping(final, self.now), (final, False))

    def test_late_result_cannot_create_or_cover_cards(self):
        before = copy.deepcopy(self.state)
        with self.assertRaisesRegex(ValueError, 'TREND_GROUPING_RETIRED'):
            g.apply_result(self.state, dict(job_id='old', groups=[]), self.now)
        self.assertEqual(self.state, before)

    def test_individual_images_need_no_clearance_but_coverage_and_anticipation_stay_blocked(self):
        for state in ('pending', 'needs_correction', '', None):
            self.assertTrue(maintenance.image_allowed(dict(editorial_grouping_state=state)))
        self.assertFalse(maintenance.image_allowed(dict(anticipation_request=True)))
        self.assertFalse(maintenance.image_allowed(dict(listas_group_role='covered')))


if __name__ == '__main__':
    unittest.main()
