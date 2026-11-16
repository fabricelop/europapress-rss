"""Durable image error identity, races, idempotency and privacy regressions."""
import copy
from datetime import datetime, timedelta, timezone
import unittest
from unittest.mock import patch

from v2.ttendencias.test_image_worker_v2 import image, fixture
from v2.ttendencias.web_top30_v2 import image_incident_for_revision


class Ledger:
    def __init__(self, queue):
        self.queue = copy.deepcopy(queue)
        self.version = 0
        self.writes = 0
        self.lose_response = False
        self.race = None
        self.drop_writes = False

    def read(self, *args): return copy.deepcopy(self.queue), str(self.version)

    def write(self, api, auth, sha, queue, message):
        if self.race:
            race, self.race = self.race, None
            race(self.queue)
            self.version += 1
            raise RuntimeError('concurrent change')
        if sha != str(self.version): raise RuntimeError('conflict')
        self.writes += 1
        if not self.drop_writes:
            self.queue = copy.deepcopy(queue)
            self.version += 1
        if self.lose_response:
            self.lose_response = False
            raise TimeoutError('lost response')
        return 'a' * 40


class ImageIncidentTests(unittest.TestCase):
    def setUp(self):
        queue, _ = fixture()
        self.tid = next(iter(queue['items']))
        self.row = queue['items'][self.tid]
        self.now = datetime.now(timezone.utc)
        self.job = {'trend_id': self.tid, 'revision': 1,
                    'editorial_sha256': self.row['capture']['sha256'],
                    'command_id': 'v2-img-' + self.tid + '-r1-a1-abcdefgh'}
        self.ledger = Ledger(queue)
        self.addCleanup(patch.stopall)
        patch.object(image.editorial, 'queue_read', self.ledger.read).start()
        patch.object(image.editorial, 'queue_write', self.ledger.write).start()
        patch.object(image.time, 'sleep', lambda _: None).start()

    def persist(self, exc=None):
        return image.persist_image_incident(None, 'never-log-this', self.job,
                    exc or RuntimeError('V2_IMAGE_NOT_READY'), at=self.now)

    def current(self): return self.ledger.queue['items'][self.tid]

    def test_exact_revision_persists_safe_cause_without_changing_editorial_text(self):
        before = copy.deepcopy(self.current())
        self.assertTrue(self.persist())
        after = self.current()
        self.assertEqual(after['capture'], before['capture'])
        self.assertEqual(after['status'], before['status'])
        incident = after['image_incident']
        self.assertEqual(incident['editorial_sha256'], self.job['editorial_sha256'])
        self.assertEqual(incident['code'], 'V2_IMAGE_NOT_READY')
        self.assertEqual(self.ledger.writes, 1)
        self.assertTrue(image_incident_for_revision(after, now=self.now))

    def test_unknown_exception_and_known_prefix_never_publish_private_material(self):
        for text in ('Authorization: Bearer secret https://chatgpt.com/c/private',
                     'V2_IMAGE_NOT_READY: cookie=private C:\\Private\\profile'):
            result = image.safe_image_failure(RuntimeError(text))
            encoded = repr(result)
            for private in ('secret', 'https://', 'cookie=', 'C:\\'):
                self.assertNotIn(private, encoded)
        known = image.safe_image_failure(RuntimeError('V2_IMAGE_GITHUB_HTTP_503'))
        self.assertEqual(known['code'], 'V2_IMAGE_GITHUB_HTTP_ERROR')

    def test_lost_write_response_reuses_the_same_incident_and_does_not_resend(self):
        self.ledger.lose_response = True
        self.assertTrue(self.persist())
        original = copy.deepcopy(self.current()['image_incident'])
        self.assertTrue(self.persist())
        self.assertEqual(self.ledger.writes, 1)
        self.assertEqual(self.current()['image_incident'], original)

    def test_successfully_saved_image_winning_the_race_is_never_overwritten(self):
        self.ledger.race = lambda q: q['items'][self.tid]['capture'].update(
            image={'status': 'saved', 'revision': 1})
        self.assertFalse(self.persist())
        self.assertNotIn('image_incident', self.current())
        self.assertEqual(self.ledger.writes, 0)

    def test_new_revision_or_newer_active_attempt_prevents_old_incident(self):
        self.current()['revision'] = 2
        self.assertFalse(self.persist())
        self.current()['revision'] = 1
        self.current()['image_progress'] = {'status': 'in_progress', 'command_id': 'another-command',
            'revision': 1, 'editorial_sha256': self.job['editorial_sha256'],
            'expires_at': (datetime.now(timezone.utc) + timedelta(minutes=10)).isoformat()}
        self.assertFalse(self.persist())
        self.assertEqual(self.ledger.writes, 0)

    def test_newer_failed_attempt_is_not_replaced_by_older_error(self):
        self.assertTrue(self.persist())
        self.current()['image_incident']['at'] = (self.now + timedelta(minutes=1)).isoformat()
        self.current()['image_incident']['command_id'] = 'newer-command'
        self.assertFalse(self.persist())
        self.assertEqual(self.ledger.writes, 1)

    def test_unverified_readback_is_never_success_and_best_effort_does_not_break_text(self):
        self.ledger.drop_writes = True
        with self.assertRaisesRegex(RuntimeError, 'PERSISTENCE_UNVERIFIED'):
            self.persist()
        self.assertFalse(image.record_image_failure(None, None, self.job, RuntimeError('private')))
        self.assertNotIn('image_incident', self.current())

    def test_projection_hides_stale_hash_saved_image_or_live_retry(self):
        self.assertTrue(self.persist())
        row = self.current()
        self.assertTrue(image_incident_for_revision(row, now=self.now))
        stale = copy.deepcopy(row)
        stale['capture']['sha256'] = 'e' * 64
        self.assertFalse(image_incident_for_revision(stale, now=self.now))
        saved = copy.deepcopy(row)
        saved['capture']['image'] = {'status': 'saved', 'revision': 1,
            'editorial_sha256': self.job['editorial_sha256'], 'sha256': 'f' * 64,
            'backend': 'github_v1_style', 'mime': 'image/png',
            'command_id': self.job['command_id'],
            'path': 'v2/ttendencias/generated-images/' + self.tid + '-r1-' + 'f' * 24 + '.png'}
        self.assertFalse(image_incident_for_revision(saved, now=self.now))
        active = copy.deepcopy(row)
        active['image_progress'] = {'status': 'in_progress', 'revision': 1,
            'editorial_sha256': self.job['editorial_sha256'],
            'expires_at': (self.now + timedelta(minutes=5)).isoformat()}
        self.assertFalse(image_incident_for_revision(active, now=self.now))


if __name__ == '__main__': unittest.main()
