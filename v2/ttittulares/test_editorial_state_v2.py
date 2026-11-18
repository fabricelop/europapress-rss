"""Editorial concurrency/fencing regressions using synthetic Git snapshots only."""
import copy
import hashlib
import json
import unittest
from io import BytesIO
from datetime import timedelta
from unittest.mock import patch

from .editorial_state_v2 import (EditorialService, EditorialGitHubStore, EditorialError,
    INDEX, QUEUE, PREFIX, job_path, record_path, allowed)
from .radar_store_v2 import StoreError, Conflict, UncertainCommit
from .radar_snapshot_v2 import plan_snapshot, sha256
from .test_radar_snapshot_v2 import fixture
from .test_radar_ingest_v2 import BASE


class MemoryEditorialStore:
    def __init__(self, docs):
        self.current = 'a' * 40
        self.commits = {self.current: copy.deepcopy(docs)}
        self.writes = []
        self.before_commit = None
        self.lose_response = False
        self.break_readback = False

    def read_editorial_snapshot(self):
        return self.current, copy.deepcopy(self.commits[self.current])

    def read_documents(self, commit, paths):
        actual = {p: copy.deepcopy(self.commits[commit][p]) for p in paths}
        if self.break_readback:
            actual.pop(next(iter(actual)))
        return actual

    def advance(self, changes):
        previous = self.commits[self.current]
        self.current = hashlib.sha1(str(len(self.commits)).encode()).hexdigest()
        self.commits[self.current] = {**copy.deepcopy(previous), **copy.deepcopy(changes)}

    def origin_commit(self, head, path):
        return next(commit for commit, docs in self.commits.items() if path in docs)

    def commit(self, expected, writes, message):
        if self.before_commit:
            callback, self.before_commit = self.before_commit, None
            callback(self)
        if expected != self.current:
            raise Conflict('fixture')
        self.advance(writes)
        self.writes.append(copy.deepcopy(writes))
        if self.lose_response:
            self.lose_response = False
            raise UncertainCommit('fixture')
        return self.current


def documents(count=4):
    docs = plan_snapshot(fixture(), {}, now=BASE)['writes']
    # Only the authorities/projections consumed by the editorial service.
    result = {INDEX: copy.deepcopy(docs[INDEX]), QUEUE: copy.deepcopy(docs[QUEUE])}
    original_event = next(d for p, d in docs.items() if p.startswith(PREFIX+'news/'))
    original_job = next(d for p, d in docs.items() if p.startswith(PREFIX+'jobs/'))
    original_index = copy.deepcopy(docs[INDEX]['items'][original_event['event_id']])
    result[INDEX]['items'] = {}
    result[QUEUE]['items'] = []
    # Reverse insert order deliberately: scheduling must use time, not dictionary order.
    for n in reversed(range(count)):
        ident = 'ttn2-' + format(n+1, '024x')
        jid = ident + '-r1-editorial'
        requested = (BASE + timedelta(seconds=n)).isoformat().replace('+00:00','Z')
        event, job = copy.deepcopy(original_event), copy.deepcopy(original_job)
        event['event_id'] = ident
        event['revision_refs'][0].update(editorial_job_id=jid, requested_at=requested)
        job.update(event_id=ident, job_id=jid, requested_at=requested)
        result[PREFIX+'news/'+ident+'.json'] = event
        result[job_path(jid)] = job
        result[INDEX]['items'][ident] = {**copy.deepcopy(original_index), 'event_id': ident,
            'revision_refs': copy.deepcopy(event['revision_refs'])}
        result[QUEUE]['items'].append({**{k: job[k] for k in
            ('job_id','event_id','revision','status','priority','requested_at')}, 'job_path':job_path(jid)})
    result[QUEUE]['pending_count'] = count
    result[QUEUE]['active_count'] = 0
    return result


class EditorialStateTests(unittest.TestCase):
    def setUp(self):
        self.now = BASE + timedelta(minutes=1)
        self.store = MemoryEditorialStore(documents())
        self.service = EditorialService(self.store, clock=lambda:self.now, lease_seconds=120)
        self.token = 'private-token-never-uploaded-0001'

    def claim(self, worker='worker-1', token=None):
        return self.service.claim(worker, token or self.token)

    def test_launch_boundary_skips_yesterday_without_erasing_pending_jobs(self):
        from .test_radar_ingest_v2 import BASE
        cutoff=(BASE+timedelta(seconds=2)).isoformat().replace('+00:00','Z')
        service=EditorialService(self.store,clock=lambda:self.now,lease_seconds=120,min_requested_at=cutoff)
        plan=service.preview()
        self.assertEqual(plan['pending_count'],2)
        self.assertEqual(plan['min_requested_at'],cutoff)
        claimed=service.claim('worker-today','today-only-private-token-123456789')
        self.assertEqual(claimed['job']['requested_at'],cutoff)
        _,after=self.store.read_editorial_snapshot()
        self.assertEqual(sum(j['status']=='pending' for p,j in after.items() if '/jobs/editorial/' in p),3)
        with self.assertRaises(EditorialError):
            EditorialService(self.store,min_requested_at='not-a-timestamp')

    def prepare(self, claim=None):
        claim = claim or self.claim()
        return self.service.prepare_send(claim['job']['job_id'], 'worker-1', self.token, 'b'*64, 'news-command-1',
            {'session_id':'session-local-1', 'private_journal_id':'journal-local-1', 'conversation_url_sha256':'c'*64})

    def captured(self):
        sent = self.prepare()
        jid = sent['job']['job_id']
        self.service.submitted(jid,'worker-1',self.token)
        return self.service.captured(jid,'worker-1',self.token,'d'*64,'capture-local-1')

    def ready_record(self, captured):
        from .test_editorial_contract_v2 import fixture as contract_fixture, reply
        from .editorial_contract_v2 import parse_record
        _, _, payload = contract_fixture()
        payload.update(event_id=captured['job']['event_id'], revision=captured['job']['revision'], command_id='news-command-1')
        for row in payload['source_evidence']:
            row['retrieved_at'] = self.now.isoformat()
        payload['verification']['verified_at'] = self.now.isoformat()
        return parse_record(reply(payload),captured['event'],captured['job'],'news-command-1',self.now)

    def test_preview_identifies_uncertain_incident_without_reclaiming_it(self):
        prepared = self.prepare()
        self.service.fail(prepared['job']['job_id'], 'worker-1', self.token,
                          code='NEWS_SUBMISSION_UNCONFIRMED_NO_RESEND', safe_preflight=False)
        plan = self.service.preview()
        self.assertEqual(plan['recovery_incident_count'], 1)
        self.assertEqual(plan['active_count'], 0)
        self.assertFalse(any(j['job_id'] == prepared['job']['job_id'] for j in plan['next_jobs']))

    def test_captured_validation_incident_is_quarantined_without_blocking_other_news(self):
        captured = self.captured()
        jid = captured["job"]["job_id"]
        self.service.fail(jid, "worker-1", self.token, code="ESSENTIAL_FACT_NOT_VERIFIED")
        before = copy.deepcopy(self.store.read_editorial_snapshot()[1][job_path(jid)])
        plan = self.service.preview()
        self.assertEqual(plan["recovery_incident_count"], 1)
        self.assertEqual(plan["blocking_recovery_incident_count"], 0)
        self.assertEqual(plan["quarantined_incident_count"], 1)
        self.assertEqual(plan["active_count"], 0)
        self.assertEqual(plan["pending_count"], 3)
        self.assertNotIn(jid, [j["job_id"] for j in plan["next_jobs"]])
        following = self.claim(worker="worker-other", token="private-other-token-1234567890")
        self.assertNotEqual(following["job"]["job_id"], jid)
        self.assertEqual(self.store.read_editorial_snapshot()[1][job_path(jid)], before)

    def test_uncertain_submission_isolated_without_blocking_independent_pending_job(self):
        sent = self.prepare()
        jid = sent["job"]["job_id"]
        self.service.fail(jid, "worker-1", self.token, code="NEWS_SUBMISSION_UNCONFIRMED_NO_RESEND")
        before = copy.deepcopy(self.store.read_editorial_snapshot()[1][job_path(jid)])
        plan = self.service.preview()
        self.assertEqual(plan["blocking_recovery_incident_count"], 1)
        self.assertEqual(plan["quarantined_incident_count"], 0)
        self.assertEqual(plan["pending_count"], 3)
        self.assertNotIn(jid, [job["job_id"] for job in plan["next_jobs"]])
        following = self.claim(worker="worker-other", token="private-other-token-1234567890")
        self.assertNotEqual(following["job"]["job_id"], jid)
        self.assertEqual(self.store.read_editorial_snapshot()[1][job_path(jid)], before)

    def test_confirmed_submission_without_complete_capture_still_needs_recovery(self):
        sent = self.prepare()
        jid = sent["job"]["job_id"]
        self.service.submitted(jid, "worker-1", self.token)
        self.service.fail(jid, "worker-1", self.token, code="NEWS_CAPTURE_TIMEOUT_NO_RESEND")
        plan = self.service.preview()
        self.assertEqual(plan["blocking_recovery_incident_count"], 1)
        self.assertEqual(plan["quarantined_incident_count"], 0)

    def test_complete_capture_does_not_override_uncertain_submission(self):
        captured = self.captured()
        jid = captured["job"]["job_id"]
        self.service.fail(jid, "worker-1", self.token, code="ESSENTIAL_FACT_NOT_VERIFIED")
        _, docs = self.store.read_editorial_snapshot()
        job = docs[job_path(jid)]
        job["send_intent"]["submission_state"] = "uncertain"
        self.store.advance({job_path(jid): job})
        self.assertEqual(self.service.preview()["blocking_recovery_incident_count"], 1)

    def quarantined(self):
        sent = self.prepare()
        jid = sent["job"]["job_id"]
        self.service.fail(jid, "worker-1", self.token, "NEWS_SUBMISSION_UNCONFIRMED_NO_RESEND")
        return jid

    def recover(self, jid, **overrides):
        values = dict(command_id="news-command-1", answer_sha256="d"*64,
                      local_journal_id="journal-local-1", cleanup_verified=True)
        values.update(overrides)
        return self.service.recover_capture(jid, "manual-recovery", "recovery-token-secret-0002", **values)

    def test_user_recovered_capture_confirms_original_send_and_never_creates_another_submission(self):
        jid = self.quarantined()
        result = self.recover(jid)
        job = result["job"]
        self.assertEqual(job["status"], "captured")
        self.assertEqual(job["send_intent"]["command_id"], "news-command-1")
        self.assertEqual(job["send_intent"]["submission_state"], "confirmed")
        self.assertEqual(job["attempts"]["submission_count"], 1)
        self.assertEqual(job["capture"]["answer_sha256"], "d"*64)
        self.assertTrue(job["capture"]["complete"])

    def test_recovery_requires_cleanup_proof_and_exact_original_attempt(self):
        for changes in ({"cleanup_verified": False}, {"command_id": "other-command"},
                        {"local_journal_id": "different-journal"}):
            with self.subTest(changes=changes):
                self.setUp()
                jid = self.quarantined()
                before = len(self.store.writes)
                with self.assertRaises(EditorialError):
                    self.recover(jid, **changes)
                self.assertEqual(len(self.store.writes), before)

    def test_recovery_is_fenced_against_another_active_worker_and_immutable_reply(self):
        jid = self.quarantined()
        self.recover(jid)
        with self.assertRaisesRegex(EditorialError, "LEASE_FENCED"):
            self.service.recover_capture(jid, "another-worker", "another-token-secret-003",
                "news-command-1", "d"*64, "journal-local-1", cleanup_verified=True)
        with self.assertRaisesRegex(EditorialError, "IMMUTABLE_CAPTURE"):
            self.recover(jid, answer_sha256="e"*64)

    def test_recovery_readback_and_ready_replay_preserve_one_immutable_record(self):
        jid = self.quarantined()
        captured = self.recover(jid)
        record = self.ready_record(captured)
        done = self.service.complete(jid, "manual-recovery", "recovery-token-secret-0002", record)
        self.assertEqual(done["job"]["status"], "ready")
        count = len(self.store.writes)
        replay = self.recover(jid)
        self.assertEqual(replay["job"]["status"], "ready")
        self.assertTrue(replay["replayed"])
        self.assertEqual(len(self.store.writes), count)

    def test_recovery_reconciles_lost_commit_response_without_second_capture(self):
        jid = self.quarantined()
        before = len(self.store.writes)
        self.store.lose_response = True
        result = self.recover(jid)
        self.assertEqual(result["job"]["status"], "captured")
        self.assertEqual(len(self.store.writes), before + 1)

    def test_recovery_respects_three_global_slots(self):
        jid = self.quarantined()
        for index in range(3):
            self.claim("other-"+str(index), "private-other-token-sufficiently-long-"+str(index))
        with self.assertRaisesRegex(EditorialError, "NO_WORKER_CAPACITY"):
            self.recover(jid)

    def test_preview_never_mutates_and_fifo_ignores_insert_order(self):
        preview = self.service.preview()
        self.assertEqual([j['event_id'] for j in preview['next_jobs']], ['ttn2-'+format(n,'024x') for n in (1,2,3)])
        self.assertFalse(preview['effects_enabled'])
        self.assertEqual(self.store.writes, [])

    def test_four_workers_cannot_exceed_three_global_slots(self):
        claims = [self.claim('worker-'+str(i), self.token+str(i)) for i in range(4)]
        self.assertEqual(sum(x['job'] is not None for x in claims),3)
        self.assertEqual(self.store.commits[self.store.current][QUEUE]['active_count'],3)
        self.assertEqual(self.store.commits[self.store.current][QUEUE]['pending_count'],1)
        self.assertEqual([c['job']['event_id'] for c in claims[:3]], ['ttn2-'+format(n,'024x') for n in (1,2,3)])

    def test_preview_reports_stale_jobs_when_no_pending_so_daemon_can_reap(self):
        self.store = MemoryEditorialStore(documents(1))
        self.service = EditorialService(self.store,clock=lambda:self.now,lease_seconds=120)
        self.claim()
        self.assertFalse(self.service.preview()['maintenance_needed'])
        self.now += timedelta(minutes=3)
        before = len(self.store.writes)
        preview = self.service.preview()
        self.assertEqual(preview['pending_count'],0)
        self.assertTrue(preview['maintenance_needed'])
        self.assertEqual(preview['stale_active_count'],1)
        self.assertEqual(len(self.store.writes),before)

    def test_cas_race_rereads_and_never_overwrites_other_claim(self):
        competitor = EditorialService(self.store, clock=lambda:self.now)
        self.store.before_commit = lambda store: competitor.claim('other-worker',self.token+'other')
        result = self.claim()
        self.assertTrue(result['job']['event_id'].endswith('2'))
        self.assertEqual(self.service.preview()['active_count'],2)

    def test_lost_claim_response_recovers_same_job_without_second_claim(self):
        self.store.lose_response = True
        result = self.claim()
        self.assertTrue(result['verified'])
        self.assertTrue(result['replayed'])
        self.assertEqual(len(self.store.writes),1)
        self.assertEqual(self.service.preview()['active_count'],1)

    def test_private_token_never_written(self):
        self.prepare()
        self.assertNotIn(self.token,json.dumps(self.store.writes))
        self.assertIn(hashlib.sha256(self.token.encode()).hexdigest(), json.dumps(self.store.writes))

    def test_only_fresh_send_intent_authorizes_one_send(self):
        claim = self.claim()
        first = self.prepare(claim)
        self.assertTrue(first['send_authorized'])
        replay = self.prepare(claim)
        self.assertFalse(replay['send_authorized'])
        self.assertEqual(replay['job']['send_intent']['command_id'],'news-command-1')

    def test_uncertain_send_intent_never_authorizes_transmission(self):
        self.claim()
        self.store.lose_response = True
        result = self.prepare()
        self.assertFalse(result['send_authorized'])
        self.assertEqual(result['job']['status'],'send_intent')
        self.assertEqual(result['job']['attempts']['submission_count'],0)

    def test_token_fencing_wrong_owner_and_expiry(self):
        jid = self.claim()['job']['job_id']
        for worker, token in [('other',self.token),('worker-1',self.token+'wrong')]:
            with self.assertRaisesRegex(EditorialError,'LEASE_FENCED'):
                self.service.heartbeat(jid,worker,token)
        self.now += timedelta(minutes=3)
        with self.assertRaisesRegex(EditorialError,'LEASE_EXPIRED'):
            self.service.heartbeat(jid,'worker-1',self.token)

    def test_confirmed_chat_hash_replaces_home_hash_without_exposing_url(self):
        jid = self.prepare()['job']['job_id']
        url = 'https://chatgpt.com/c/private-test-conversation-1'
        actual = hashlib.sha256(url.encode()).hexdigest()
        result = self.service.submitted(jid,'worker-1',self.token,conversation_url_sha256=actual)
        self.assertEqual(result['job']['session']['conversation_url_sha256'],actual)
        self.assertNotIn(url,json.dumps(self.store.writes))
        self.assertTrue(self.service.submitted(jid,'worker-1',self.token,conversation_url_sha256=actual)['replayed'])
        with self.assertRaisesRegex(EditorialError,'CONVERSATION_HASH_CHANGED'):
            self.service.submitted(jid,'worker-1',self.token,conversation_url_sha256='e'*64)
        with self.assertRaisesRegex(EditorialError,'INVALID_CONFIRMED_CONVERSATION_HASH'):
            self.service.submitted(jid,'worker-1',self.token,conversation_url_sha256=url)

    def test_heartbeat_extends_lease_without_faking_radar_freshness(self):
        claim = self.claim()
        initial = self.store.commits[self.store.current][INDEX]['updated_at']
        self.now += timedelta(seconds=30)
        result = self.service.heartbeat(claim['job']['job_id'],'worker-1',self.token)
        self.assertGreater(result['job']['lease']['expires_at'],claim['job']['lease']['expires_at'])
        docs = self.store.commits[self.store.current]
        self.assertEqual(docs[INDEX]['updated_at'],initial)
        self.assertEqual(docs[INDEX]['updated_at'],docs[QUEUE]['updated_at'])

    def test_expired_pre_send_can_be_claimed_again_but_intent_is_never_requeued(self):
        first = self.claim()
        self.now += timedelta(minutes=3)
        reclaimed = self.claim('worker-2',self.token+'2')
        self.assertEqual(first['job']['job_id'],reclaimed['job']['job_id'])
        self.assertEqual(reclaimed['job']['attempts']['claim_count'],2)
        # separate fixture with a durable possible-send boundary
        self.setUp()
        sent = self.prepare()
        self.now += timedelta(minutes=3)
        self.claim('worker-2',self.token+'2')
        previous = self.store.commits[self.store.current][job_path(sent['job']['job_id'])]
        self.assertEqual(previous['status'],'problematic')
        self.assertEqual(previous['problem']['retry_mode'],'recover_same_chat')

    def test_safe_preflight_failure_retries_only_before_any_intent(self):
        jid = self.claim()['job']['job_id']
        result = self.service.fail(jid,'worker-1',self.token,'LOGIN_REQUIRED',safe_preflight=True)
        self.assertEqual(result['job']['status'],'pending')
        sent = self.prepare()
        result = self.service.fail(sent['job']['job_id'],'worker-1',self.token,'SEND_UNCERTAIN',safe_preflight=True)
        self.assertEqual(result['job']['status'],'problematic')
        self.assertEqual(result['job']['send_intent']['submission_state'],'uncertain')

    def test_terminal_event_wins_between_claim_and_send(self):
        claim = self.claim()
        path = PREFIX+'news/'+claim['job']['event_id']+'.json'
        event = copy.deepcopy(self.store.commits[self.store.current][path]); event['status']='dismissed'
        self.store.advance({path:event})
        with self.assertRaisesRegex(EditorialError,'TERMINAL_OR_NEW_REVISION'):
            self.prepare(claim)

    def test_terminal_decision_wins_even_before_event_projection_is_applied(self):
        claim = self.claim()
        event_id = claim['job']['event_id']
        did = 'dcn2-'+'1'*24
        doc = {'schema_version':1,'project':'ttittulares-v2','decision_id':did,'event_id':event_id,
               'revision':1,'action':'dismiss','actor':'test','occurred_at':self.now.isoformat(),
               'idempotency_key':'test-dismiss-1'}
        self.store.advance({PREFIX+'decisions/'+event_id+'/'+did+'.json':doc})
        with self.assertRaisesRegex(EditorialError,'TERMINAL_OR_NEW_REVISION'):
            self.prepare(claim)

    def test_new_revision_wins_during_ready_commit(self):
        claim = self.captured()
        path = PREFIX+'news/'+claim['job']['event_id']+'.json'
        event = copy.deepcopy(self.store.commits[self.store.current][path])
        # JIT notices new revision even while current job's READY is being prepared.
        event['current_revision']=2
        self.store.advance({path:event})
        with self.assertRaisesRegex(EditorialError,'TERMINAL_OR_NEW_REVISION'):
            self.service.complete(claim['job']['job_id'],'worker-1',self.token,{})

    def test_capture_requires_confirmed_submission_and_is_immutable(self):
        claim = self.claim()
        with self.assertRaisesRegex(EditorialError,'RESPONSE_NOT_AWAITED'):
            self.service.captured(claim['job']['job_id'],'worker-1',self.token,'d'*64,'local-1')
        capture = self.captured()
        result = self.service.captured(capture['job']['job_id'],'worker-1',self.token,'d'*64,'capture-local-1')
        self.assertTrue(result['replayed'])
        with self.assertRaisesRegex(EditorialError,'CAPTURE_MISMATCH'):
            self.service.captured(capture['job']['job_id'],'worker-1',self.token,'e'*64,'local-2')

    def test_complete_persists_record_then_ready_with_original_record_commit(self):
        captured = self.captured()
        record = self.ready_record(captured)
        before = len(self.store.writes)
        result = self.service.complete(captured['job']['job_id'],'worker-1',self.token,record)
        self.assertTrue(result['verified'])
        self.assertEqual(len(self.store.writes),before+2)
        self.assertEqual(result['job']['status'],'ready')
        self.assertEqual(result['event']['status'],'ready')
        self.assertIsNone(result['job']['lease'])
        path = record_path(result['job'])
        self.assertEqual(result['job']['result']['record_sha256'],sha256(record))
        origin = result['job']['result']['commit_sha']
        self.assertEqual(self.store.commits[origin][path],record)
        self.assertNotEqual(origin,result['commit_sha'])
        docs = self.store.commits[self.store.current]
        self.assertEqual(docs[INDEX]['items'][record['event_id']]['status'],'ready')
        self.assertEqual(next(j for j in docs[QUEUE]['items'] if j['job_id']==record['editorial_job_id'])['status'],'ready')
        # Completing the same capture after success cannot create another commit.
        replay = self.service.complete(captured['job']['job_id'],'worker-1',self.token,record)
        self.assertEqual(len(self.store.writes),before+2)
        self.assertTrue(replay['replayed'])

    def test_uncertain_record_write_recovers_exact_bytes_without_duplicate(self):
        captured = self.captured()
        record = self.ready_record(captured)
        before = len(self.store.writes)
        self.store.lose_response = True
        result = self.service.complete(captured['job']['job_id'],'worker-1',self.token,record)
        self.assertEqual(result['job']['status'],'ready')
        self.assertEqual(len(self.store.writes),before+2)

    def test_existing_ready_bytes_cannot_be_overwritten(self):
        captured = self.captured()
        record = self.ready_record(captured)
        self.service.complete(captured['job']['job_id'],'worker-1',self.token,record)
        changed = copy.deepcopy(record);changed['tweet']['text'] += '!'
        with self.assertRaisesRegex(EditorialError,'READY_MISMATCH'):
            self.service.complete(captured['job']['job_id'],'worker-1',self.token,changed)

    def test_human_terminal_winning_cas_prevents_persisting_any_ready_record(self):
        captured = self.captured()
        record = self.ready_record(captured)
        event_path = PREFIX+'news/'+captured['job']['event_id']+'.json'
        def dismiss(store):
            event=copy.deepcopy(store.commits[store.current][event_path]);event['status']='dismissed'
            store.advance({event_path:event})
        self.store.before_commit=dismiss
        with self.assertRaisesRegex(EditorialError,'TERMINAL_OR_NEW_REVISION'):
            self.service.complete(captured['job']['job_id'],'worker-1',self.token,record)
        self.assertNotIn(record_path(captured['job']),self.store.commits[self.store.current])

    def test_readback_failure_never_reports_success(self):
        self.store.break_readback=True
        with self.assertRaisesRegex(EditorialError,'READBACK_MISMATCH'):
            self.claim()

    def test_session_cannot_publish_a_conversation_url(self):
        jid=self.claim()['job']['job_id']
        with self.assertRaisesRegex(EditorialError,'PRIVATE_SESSION'):
            self.service.prepare_send(jid,'worker-1',self.token,'a'*64,'news-1',
                {'session_id':'https://chatgpt.com/c/private','private_journal_id':'local-1',
                 'conversation_url_sha256':'b'*64})

    def test_v1_and_unrelated_write_paths_are_rejected_before_network(self):
        store=EditorialGitHubStore('test-token',request=lambda *a: self.fail('network touched'))
        for path in ['ttittulares/prepared.json','v2/ttendencias/state/editorial-queue.json',
                     PREFIX+'state/radar/current.json',PREFIX+'decisions/ttn2-'+'a'*24+'/dcn2-'+'b'*24+'.json']:
            self.assertFalse(allowed(path,write=True))
            with self.assertRaisesRegex(EditorialError,'PATH_OUTSIDE_SCOPE'):
                store.commit('a'*40,{path:{}},'fixture')


class EditorialWireTests(unittest.TestCase):
    def test_commit_uses_fixed_v2_branch_server_cas_without_deletions(self):
        calls=[]
        def request(method,path,payload=None):
            calls.append((method,path,payload))
            return {'data':{'createCommitOnBranch':{'commit':{'oid':'b'*40}}}}
        store=EditorialGitHubStore('private-test-token',request=request)
        path=PREFIX+'records/ttn2-'+'1'*24+'/r1.json'
        self.assertEqual(store.commit('a'*40,{path:{'fixture':True}},'test'),'b'*40)
        method,endpoint,payload=calls[0]
        self.assertEqual((method,endpoint),('POST','/graphql'))
        value=payload['variables']['input']
        self.assertEqual(value['expectedHeadOid'],'a'*40)
        self.assertEqual(value['branch']['branchName'],'feature/ttactualidad-v2-clean')
        self.assertEqual(value['branch']['repositoryNameWithOwner'],'fabricelop/europapress-rss')
        self.assertNotIn('deletions',value['fileChanges'])

    def test_pinned_record_raw_request_never_sends_github_credentials(self):
        requests=[]
        class Opener:
            def open(self,request,timeout):
                requests.append(request)
                return BytesIO(b'{}')
        store=EditorialGitHubStore('private-test-token')
        store._opener=Opener()
        path=PREFIX+'records/ttn2-'+'1'*24+'/r1.json'
        self.assertEqual(store._http_raw('a'*40,path),b'{}')
        self.assertIn('/'+'a'*40+'/',requests[0].full_url)
        self.assertNotIn('Authorization',requests[0].headers)
        self.assertNotIn('private-test-token',str(requests[0].headers))

    def test_blob_cache_is_sha_bound_and_returns_independent_copies(self):
        raw=b'{"value":1}'
        oid=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
        calls=[]
        def read(commit,path):
            calls.append((commit,path));return raw
        store=EditorialGitHubStore('private-test-token',read_bytes=read)
        entry={'sha':oid,'mode':'100644','type':'blob'}
        path=job_path('ttn2-'+'1'*24+'-r1-editorial')
        first=store._blob_json(entry,'a'*40,path)
        first['value']=99
        second=store._blob_json(entry,'b'*40,path)
        self.assertEqual(second,{'value':1})
        self.assertEqual(len(calls),1)
        with self.assertRaisesRegex(StoreError,'HASH_MISMATCH'):
            store._blob_json({**entry,'sha':'f'*40},'b'*40,path)


if __name__=='__main__':
    unittest.main()
