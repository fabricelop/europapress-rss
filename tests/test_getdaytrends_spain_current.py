"""Read-only contract: Spain current rankings must not use 24h hashtags or other feeds."""
import unittest
from pathlib import Path
from importlib.util import spec_from_file_location, module_from_spec

spec=spec_from_file_location('tt_radar',Path(__file__).resolve().parents[1]/'trends/update_trends.py')
mod=module_from_spec(spec)
spec.loader.exec_module(mod)

class GetDayTrendsSpainContract(unittest.TestCase):
 def test_now_ranked_table_not_daily_hashtags(self):
  html='''<h1>Tendencias de Twitter España</h1><h2>Tendencias Ahora</h2><table><tr><th>#</th><th>Tendencia</th></tr>'''+''.join(f'<tr><td>{i}</td><td><a href="/trend/now-{i}/">Ahora {i}</a></td></tr>' for i in range(1,31))+'''</table><h2>Top Hashtags 24h</h2><table><tr><td>1</td><td>#Ayer</td></tr></table>'''
  self.assertEqual(mod.parse_getdaytrends(html),[f'Ahora {i}' for i in range(1,31)])
 def test_geographic_guard_does_not_ban_foreign_named_spanish_trends(self):
  self.assertFalse(mod.source_page_explicitly_foreign('<h1>Tendencias de Twitter España</h1>'))
  self.assertTrue(mod.source_page_explicitly_foreign('<h1>Twitter trending in Thailand</h1>'))

if __name__=='__main__': unittest.main()
