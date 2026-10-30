import copy
import importlib.util
from pathlib import Path
import unittest
from datetime import datetime, timezone, timedelta

spec=importlib.util.spec_from_file_location('listas_grouping',Path(__file__).with_name('listas_grouping.py'))
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class ListasGroupingTests(unittest.TestCase):
    def setUp(self):
        self.now=datetime(2026,10,30,7,tzinfo=timezone.utc)
        self.state={p:{'items':[]} for p in [m.MANUAL,m.QUEUE,m.DECISIONS,m.DELIVERIES,m.RECEIPTS]}
        self.state[m.REQUESTS]={'requests':[]}
        for ident,name in [('a123','Adif'),('b123','Atocha'),('c123','Copa')]:
            row={'id':ident,'revision':1,'status':'explained','name':name,'rank':2,
                 'explanation':'Explicación original e inmutable de '+name,
                 'closer_text':'','explained_at':(self.now-timedelta(hours=1)).isoformat()}
            self.state[m.MANUAL]['items'].append(copy.deepcopy(row))
            self.state[m.REQUESTS]['requests'].append(copy.deepcopy(row))
        self.payload={'project':'ttendencias','decision':'group_listas','request_id':'12345678-1234-4234-8234-123456789abc'}

    def requested(self):
        return m.request(self.state,self.payload,self.now)[0]

    def result(self):
        return {'job_id':'listas-grouping-'+self.payload['request_id'],'groups':[{
            'name':'Investigación ferroviaria','explanation':'TT#2 Adif y Atocha son tendencia por la investigación ferroviaria.\n#Adif #Atocha',
            'closer_text':'','reason':'Ambas explicaciones se refieren al mismo episodio verificado.',
            'verification_sources':[{'url':'https://example.org/comunicado'}],
            'members':[{'id':'a123','revision':1},{'id':'b123','revision':1}]}]}

    def test_request_snapshots_all_without_changing_existing_text_or_status(self):
        state=self.requested()
        self.assertEqual(state[m.MANUAL],self.state[m.MANUAL])
        self.assertEqual(state[m.REQUESTS]['requests'][:3],self.state[m.REQUESTS]['requests'])
        self.assertEqual(len(state[m.QUEUE]['items'][0]['grouping_candidates']),3)

    def test_same_request_and_second_tap_are_idempotent(self):
        state=self.requested()
        self.assertEqual(m.request(state,self.payload,self.now),(state,False))
        again={**self.payload,'request_id':'22345678-1234-4234-8234-123456789abc'}
        state,_=m.request(state,again,self.now)
        self.assertEqual(len(state[m.QUEUE]['items']),1)
        self.assertEqual(state[m.RECEIPTS]['items'][-1]['status'],'already_applied')

    def test_joint_card_preserves_every_original_explanation_date_and_revision(self):
        state,_=m.apply_result(self.requested(),self.result(),self.now)
        parent=state[m.MANUAL]['items'][-1]
        self.assertEqual(parent['listas_group_role'],'joint')
        for path,field in [(m.MANUAL,'items'),(m.REQUESTS,'requests')]:
            for old in self.state[path][field]:
                new=next(x for x in state[path][field] if x['id']==old['id'])
                for key in ('explanation','closer_text','explained_at','revision','status'):
                    self.assertEqual(new[key],old[key])
                if old['id'] in {'a123','b123'}:
                    self.assertEqual(new['covered_by_id'],parent['id'])
                else:self.assertNotIn('covered_by_id',new)
        self.assertEqual(state[m.QUEUE]['items'],[])
        self.assertEqual(state[m.RECEIPTS]['items'],self.requested()[m.RECEIPTS]['items'])

    def test_repeated_outbox_does_not_duplicate_joint_card(self):
        state,_=m.apply_result(self.requested(),self.result(),self.now)
        self.assertEqual(m.apply_result(state,self.result(),self.now),(state,False))

    def test_deleted_or_revised_or_changed_member_skips_entire_group(self):
        for change in ('deleted','revision','text'):
            state=self.requested()
            row=state[m.MANUAL]['items'][0]
            if change=='deleted':row['status']='deleted'
            elif change=='revision':row['revision']=2
            else:row['explanation']='Nueva explicación'
            result,_=m.apply_result(state,self.result(),self.now)
            self.assertEqual(len(result[m.MANUAL]['items']),3)
            self.assertFalse(any(x.get('covered_by_id') for x in result[m.MANUAL]['items']))
            self.assertEqual(result[m.REQUESTS]['requests'][-1]['grouping_skipped_stale'],[['a123','b123']])

    def test_invented_duplicate_and_wrong_revision_members_rejected_without_mutation(self):
        for members in [[{'id':'fake','revision':1},{'id':'b123','revision':1}],
                        [{'id':'a123','revision':2},{'id':'b123','revision':1}],
                        [{'id':'a123','revision':1},{'id':'a123','revision':1}]]:
            state=self.requested();before=copy.deepcopy(state);command=self.result()
            command['groups'][0]['members']=members
            with self.assertRaises(ValueError):m.apply_result(state,command,self.now)
            self.assertEqual(state,before)

    def test_no_similar_topics_finishes_without_creating_or_covering_cards(self):
        command=self.result();command['groups']=[]
        state,_=m.apply_result(self.requested(),command,self.now)
        self.assertEqual(state[m.MANUAL],self.state[m.MANUAL])
        self.assertEqual(state[m.REQUESTS]['requests'][-1]['status'],'grouping_completed')

    def test_cleanup_only_selected_covered_cards_without_publication_or_parent_deletion(self):
        state,_=m.apply_result(self.requested(),self.result(),self.now)
        parent=state[m.MANUAL]['items'][-1]
        command={**self.payload,'decision':'remove_covered','request_id':'32345678-1234-4234-8234-123456789abc',
                 'items':[{'id':'a123','revision':1},{'id':parent['id'],'revision':0},{'id':'c123','revision':1}]}
        cleaned,_=m.request(state,command,self.now)
        by_id={x['id']:x for x in cleaned[m.MANUAL]['items']}
        self.assertEqual(by_id['a123']['status'],'deleted')
        self.assertEqual(by_id['a123']['explanation'],self.state[m.MANUAL]['items'][0]['explanation'])
        self.assertEqual(by_id['b123']['status'],'explained')
        self.assertEqual(by_id['c123']['status'],'explained')
        self.assertEqual(by_id[parent['id']]['status'],'explained')
        self.assertEqual(cleaned[m.RECEIPTS]['items'][-1]['skipped_count'],2)
        self.assertEqual(cleaned[m.DECISIONS]['items'][0]['status'],'deleted')

    def test_expired_and_terminal_cards_are_excluded(self):
        self.state[m.MANUAL]['items'][0]['explained_at']=(self.now-timedelta(hours=49)).isoformat()
        self.state[m.DECISIONS]['items'].append({'id':'b123','revision':1,'status':'published'})
        state=self.requested()
        self.assertEqual(state[m.QUEUE]['items'],[])
        self.assertEqual(state[m.RECEIPTS]['items'][-1]['status'],'rejected')

    def test_joint_summary_requires_sources_valid_members_and_short_tweet(self):
        for field,value in [('verification_sources',[]),('explanation','TT#2 '+'界'*200),('closer_text','🌶️ no está al final')]:
            command=self.result();command['groups'][0][field]=value
            with self.assertRaises(ValueError):m.apply_result(self.requested(),command,self.now)

    def test_existing_action_handler_rejects_publishing_covered_but_allows_delete(self):
        import tempfile, json
        spec=importlib.util.spec_from_file_location('grouping_actions',Path(__file__).with_name('apply-ttactualidad-action.py'))
        actions=importlib.util.module_from_spec(spec);spec.loader.exec_module(actions)
        state,_=m.apply_result(self.requested(),self.result(),self.now)
        with tempfile.TemporaryDirectory() as directory:
            actions.ROOT=Path(directory)
            for path,data in {**state,'trends/prepared.json':{'items':[]}}.items():
                target=Path(directory)/path;target.parent.mkdir(parents=True,exist_ok=True)
                target.write_text(json.dumps(data))
            with self.assertRaisesRegex(actions.InvalidAction,'agrupada'):
                actions.apply('ttendencias','a123','published',1)
            changed,status=actions.apply('ttendencias','a123','deleted',1)
            self.assertEqual(status,'applied')
            row=next(x for x in changed[m.MANUAL]['items'] if x['id']=='a123')
            self.assertEqual(row['explanation'],self.state[m.MANUAL]['items'][0]['explanation'])
            self.assertEqual(row['status'],'deleted')

    def test_new_revision_does_not_inherit_prior_coverage(self):
        state,_=m.apply_result(self.requested(),self.result(),self.now)
        for path,field in [(m.MANUAL,'items'),(m.REQUESTS,'requests')]:
            row=next(x for x in state[path][field] if x['id']=='a123')
            row.update(revision=2,explanation='Noticia nueva y comprobada')
        current=m.eligible(state,self.now)
        self.assertIn('a123',current)
        command={**self.payload,'decision':'remove_covered','request_id':'42345678-1234-4234-8234-123456789abc',
                 'items':[{'id':'a123','revision':2}]}
        cleaned,_=m.request(state,command,self.now)
        self.assertEqual(next(x for x in cleaned[m.MANUAL]['items'] if x['id']=='a123')['status'],'explained')
        self.assertEqual(cleaned[m.RECEIPTS]['items'][-1]['status'],'rejected')

    def test_old_closure_does_not_hide_a_later_legacy_episode(self):
        self.state[m.DECISIONS]['items']=[{'id':'a123','revision':1,'status':'deleted',
            'updated_at':(self.now-timedelta(days=3)).isoformat()}]
        self.assertIn('a123',m.eligible(self.state,self.now))
        self.state[m.DECISIONS]['items'][0]['updated_at']=self.now.isoformat()
        self.assertNotIn('a123',m.eligible(self.state,self.now))

if __name__=='__main__':unittest.main()
