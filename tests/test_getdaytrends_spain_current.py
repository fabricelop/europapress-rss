"""GetDayTrends Spain Now ranking: exact visible + collapsed table ordering."""
import unittest
from pathlib import Path
from importlib.util import spec_from_file_location, module_from_spec
from unittest.mock import patch

spec=spec_from_file_location('tt_radar',Path(__file__).resolve().parents[1]/'trends/update_trends.py')
mod=module_from_spec(spec)
spec.loader.exec_module(mod)

def row(i,name):
    return f'<tr><td>{i}</td><td><a href="/trend/{i}/">{name}</a></td></tr>'

def fixture():
    return (
        '<h1>Tendencias de Twitter España</h1>'
        '<table class="table ranking trends wider mb-0">'
        + ''.join(row(i, f'España actual {i}') for i in range(1,16))
        + '</table>'
        '<table class="table ranking trends wider collapse" id="moreTrends">'
        + ''.join(row(i, f'España actual {i}') for i in range(16,51))
        + '</table>'
        '<h2>Top Hashtags 24h</h2>'
        '<table class="table ranking top"><tr><td>1</td><td>#Antiguo</td></tr></table>'
    )

class GetDayTrendsSpainContract(unittest.TestCase):
    def test_actual_15_plus_35_html_tables_return_50_sequential_positions(self):
        ranked=mod.parse_getdaytrends(fixture())
        self.assertEqual(len(ranked),50)
        self.assertEqual(ranked[:3],['España actual 1','España actual 2','España actual 3'])
        self.assertEqual(ranked[14],'España actual 15')
        self.assertEqual(ranked[15],'España actual 16')
        self.assertEqual(ranked[29],'España actual 30')
        self.assertEqual(ranked[-1],'España actual 50')
        self.assertNotIn('#Antiguo',ranked)

    def test_only_source_actual_names_enter_direct_top30_no_other_country_or_24h(self):
        ranked=mod.parse_getdaytrends(fixture())
        source_data={'getdaytrends':{'ok':True,'trends':ranked,'freshness':'unknown'},
                     'playersells':{'ok':True,'trends':['Tendencia ajena']*50,'freshness':'fresh'}}
        selected=mod.getdaytrends_current_ranked(source_data)
        self.assertEqual(len(selected),30)
        self.assertEqual(selected,[f'España actual {i}' for i in range(1,31)])
        self.assertNotIn('Tendencia ajena',selected)

    def test_country_must_be_explicitly_spain_and_not_global(self):
        self.assertTrue(mod.getdaytrends_spain_page(fixture()))
        self.assertTrue(mod.getdaytrends_spain_page('<h1>Twitter Trends in Spain</h1>'))
        self.assertFalse(mod.getdaytrends_spain_page('<h1>Twitter Trends Worldwide</h1>'))
        self.assertFalse(mod.getdaytrends_spain_page('<h1>Twitter Trends in Thailand</h1>'))
        with patch.object(mod,'get',return_value='<h1>Twitter Trends Worldwide</h1>'+fixture().split('</h1>',1)[1]):
            observed=mod.fetch_source('getdaytrends')
        self.assertFalse(observed['ok'])
        self.assertEqual(observed['freshness'],'invalid')

    def test_reject_conflicting_positions_and_missing_middle_page(self):
        # Duplicate ordinal inside the second current-trends table.
        conflict=fixture().replace(row(16,'España actual 16'),
                                   row(16,'España actual 16')+row(16,'Otro puesto 16'))
        self.assertEqual(mod.parse_getdaytrends(conflict),[])
        no_hidden=fixture().replace('<table class="table ranking trends wider collapse" id="moreTrends">'
                    + ''.join(row(i, f'España actual {i}') for i in range(16,51)) + '</table>','')
        self.assertEqual(len(mod.parse_getdaytrends(no_hidden)),15)
        self.assertEqual(mod.getdaytrends_current_ranked({'getdaytrends':{
            'ok':True,'trends':mod.parse_getdaytrends(no_hidden),'freshness':'unknown'}}),[])

    def test_undated_frozen_source_never_replaces_current_radar(self):
        source={'getdaytrends':{'ok':True,'trends':mod.parse_getdaytrends(fixture()),'freshness':'stale'}}
        self.assertEqual(mod.getdaytrends_current_ranked(source),[])

    def test_foreign_topic_names_in_spain_are_not_geographically_blocked(self):
        self.assertFalse(mod.source_page_explicitly_foreign('<h1>Tendencias de Twitter España</h1>'))
        self.assertTrue(mod.source_page_explicitly_foreign('<h1>Twitter trends in Thailand</h1>'))

if __name__=='__main__': unittest.main()
