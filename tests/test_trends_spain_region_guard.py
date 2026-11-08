"""Fail-closed geographic evidence for third-party X Spain ranking feeds."""
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "tt_update_trends_geo", ROOT / "trends" / "update_trends.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def ranked_table(*names):
    rows = "".join(f"<tr><td>{i}</td><td>{value}</td></tr>"
                   for i, value in enumerate(names, 1))
    return "<table>" + rows + "</table>"


SPANISH_NAMES = (
    "Cracovia", "Maffeo", "Valencia", "Mestalla", "Paraguay",
    "Robe", "Broncano", "Nadal", "Aguirre", "FelizDomingo",
    "Vinicius", "laSexta"
)


class SpainSourceGuardTests(unittest.TestCase):
    def test_only_canonical_spain_trends24_endpoint_is_configured(self):
        self.assertEqual(module.SOURCES["trends24"], "https://trends24.in/spain/")

    def test_other_country_h1_is_rejected_even_with_latin_script(self):
        html = "<h1>Twitter Trends in United States</h1>" + ranked_table(*SPANISH_NAMES)
        self.assertTrue(module.source_page_explicitly_foreign(html))
        with patch.object(module, "get", return_value=html):
            result = module.fetch_source("getdaytrends")
        self.assertFalse(result["ok"])
        self.assertEqual(result["freshness"], "invalid")
        self.assertIn("otra región", result["error"])

    def test_non_spain_country_meta_is_rejected(self):
        html = '<meta name="geo.country" content="TH">' + ranked_table(*SPANISH_NAMES)
        self.assertTrue(module.source_page_explicitly_foreign(html))

    def test_spain_ranking_with_foreign_named_topics_is_allowed(self):
        html = "<h1>Twitter Trends in Spain</h1>" + ranked_table(*SPANISH_NAMES)
        html += "<footer>World: Thailand, India, Mexico</footer>"
        self.assertFalse(module.source_page_explicitly_foreign(html))
        with patch.object(module, "get", return_value=html):
            result = module.fetch_source("getdaytrends")
        self.assertTrue(result["ok"])
        self.assertIn("Paraguay", result["trends"])

    def test_snapshot_with_two_thai_script_names_is_not_a_spain_ranking(self):
        items = ["ภาษาไทย", "ประเทศไทย"] + list(SPANISH_NAMES)
        self.assertTrue(module.obviously_foreign_snapshot(items))
        self.assertFalse(module.sane_trend_list(items))

    def test_legitimate_foreign_people_and_places_not_blacklisted(self):
        names = ["Paraguay", "Tailandia", "Trump", "Cracovia",
                 "Brasil", "Mundial", "Madrid", "Barcelona",
                 "Robe", "Nadal", "Maffeo", "Vinicius"]
        self.assertTrue(module.sane_trend_list(names))


if __name__ == "__main__":
    unittest.main()
