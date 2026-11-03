import copy
import importlib.util
import unittest
from pathlib import Path
from datetime import datetime, timedelta, timezone

base = Path(__file__).resolve().parents[1] / 'trends' / 'rank_movement.py'
if not base.exists():
    base = Path(__file__).with_name('rank_movement.py')
spec = importlib.util.spec_from_file_location('rank_movement', base)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class PersistentMovement(unittest.TestCase):
    def setUp(self):
        self.names = ['Tema %d' % i for i in range(1, 31)]
        self.now = datetime(2026, 11, 3, 10, tzinfo=timezone.utc)
        self.baseline = self.capture(self.names,{},0)
    def capture(self, names, previous, minutes):
        moment=self.now+timedelta(minutes=minutes)
        items=m.rank_items(names,previous,moment)
        return {'top30':names,'items':items,'rank_movement_history':m.movement_history(previous,items,moment)}
    def topic(self, document, name='Tema 8'):
        return next(row for row in document['items'] if row['name'] == name)
    def move(self, names, name, rank):
        names = list(names); names.remove(name); names.insert(rank-1, name); return names
    def test_repeated_ranks_preserve_last_effective_change_and_time(self):
        names = self.move(self.names, 'Tema 8', 6)
        first = self.capture(names, self.baseline, 10)
        second = self.capture(names, first, 20)
        third = self.capture(names, second, 40)
        self.assertEqual(self.topic(first), self.topic(third))
        self.assertEqual((self.topic(third)['movement'], self.topic(third)['rank_delta']), ('up', 2))
        reversed_ = self.capture(self.move(names, 'Tema 8', 7), third, 50)
        row = self.topic(reversed_)
        self.assertEqual((row['movement'], row['previous_rank'], row['rank_delta']), ('down', 6, -1))
    def test_whole_top30_and_legacy_baseline_do_not_invent_new_entries(self):
        legacy = {'top10': self.names[:10], 'top30': self.names,
                  'items': [{'name': n, 'rank': i+1, 'movement': 'new'} for i,n in enumerate(self.names)]}
        rows = self.capture(self.names, legacy, 10)['items']
        self.assertTrue(all(row['movement'] == 'flat' for row in rows))
        changed = self.capture(self.move(self.names, 'Tema 25', 20), legacy, 10)
        self.assertEqual(self.topic(changed,'Tema 25')['rank_delta'],5)
    def test_new_entry_persists_then_expires_after_one_hour(self):
        names = ['Nueva'] + self.names[:29]
        first = self.capture(names,self.baseline,10)
        before = self.capture(names,first,69)
        after = self.capture(names,before,70)
        self.assertEqual(self.topic(before,'Nueva')['movement'],'new')
        self.assertEqual(self.topic(after,'Nueva')['movement'],'flat')
        self.assertEqual(self.topic(first,'Nueva')['entered_top30_at'],self.topic(after,'Nueva')['entered_top30_at'])
    def test_new_entry_changes_to_direction_on_first_real_move(self):
        names = ['Nueva'] + self.names[:29]
        first = self.capture(names,self.baseline,10)
        second = self.capture(self.move(names,'Nueva',3),first,20)
        self.assertEqual((self.topic(second,'Nueva')['movement'],self.topic(second,'Nueva')['rank_delta']),('down',-2))
    def test_return_after_full_ranking_absence_is_not_new(self):
        absent = self.capture(['Nueva']+self.names[:29],self.baseline,10)
        returned = self.capture(self.names,absent,20)
        self.assertNotEqual(self.topic(returned,'Tema 30')['movement'],'new')
    def test_incomplete_or_first_snapshot_cannot_prove_new(self):
        rows = m.rank_items(self.names, {'top10':self.names[:10],'top30':self.names[:10]},self.now)
        self.assertTrue(all(row['movement']=='flat' for row in rows))
    def test_normalized_names_preserve_history_without_mutation(self):
        before=copy.deepcopy(self.baseline)
        self.capture(self.names,self.baseline,10)
        self.assertEqual(before,self.baseline)
        self.assertEqual(m.name_key('#Mazón'),m.name_key('mazon'))
    def test_export_preserves_movement_and_editorial_content(self):
        export_spec = importlib.util.spec_from_file_location('export_top30', base.with_name('export_site_top30.py'))
        exporter = importlib.util.module_from_spec(export_spec)
        export_spec.loader.exec_module(exporter)
        names = self.move(self.names,'Tema 8',6)
        recent = self.capture(names,self.baseline,10)
        recent['captured_at'] = self.now.isoformat()
        explanation = {'id':'test-topic-8','name':'Tema 8','explanation':'Texto conservado',
                       'explained_at':self.now.isoformat(),'revision':0,'status':'published'}
        feed = exporter.export_top30(recent,{'items':[explanation]},{},{},{},now=self.now)
        row = self.topic(feed)
        self.assertEqual(row['explanation'],'Texto conservado')
        self.assertEqual(row['editorial_id'],'test-topic-8')
        for field in ('movement_version','movement','previous_rank','rank_delta','last_changed_at','entered_top30_at'):
            self.assertEqual(row[field],self.topic(recent)[field])

    def test_corrupt_sticky_delta_is_not_reused(self):
        self.baseline['items'][7].update(movement='up',previous_rank=10,rank_delta=99)
        self.assertEqual(self.topic(self.capture(self.names,self.baseline,10))['movement'],'flat')

class MigrationTests(unittest.TestCase):
    def test_legacy_new_flags_are_cleared_without_inventing_history(self):
        now=datetime(2026,11,3,10,tzinfo=timezone.utc)
        names=['Old %d'%i for i in range(30)]
        previous={'top30':names,'items':[{'name':n,'rank':i+1,'movement_version':2,'movement':'new','entered_top30_at':now.isoformat()} for i,n in enumerate(names)]}
        self.assertTrue(all(row['movement']=='flat' for row in m.rank_items(names,previous,now)))
    def test_known_radar_topic_does_not_get_a_new_label_or_invented_delta(self):
        now=datetime(2026,11,3,10,tzinfo=timezone.utc)
        names=['Known']+['Old %d'%i for i in range(29)]
        previous={'top30':['Different'],'radar_history':{'known':{'name':'Known','first_detected_at':'2026-11-02T10:00:00Z','last_seen_at':now.isoformat()}}}
        row=m.rank_items(names,previous,now)[0]
        self.assertEqual(row['movement'],'flat');self.assertIsNone(row['rank_delta'])

if __name__ == '__main__': unittest.main()
