import json
import unittest
from pathlib import Path

from shared.cross_account_story_matcher import classify_story_pair
from shared.cross_account_x_search import build_x_account_search_url


class CrossAccountStoryMatcherTests(unittest.TestCase):
    def test_feature_is_disabled_by_default(self):
        cfg = json.loads(
            (Path(__file__).with_name("cross_account_story_config.json"))
            .read_text(encoding="utf-8")
        )
        self.assertFalse(cfg["enabled"])
        self.assertEqual(cfg["mode"], "observe_only")
        self.assertFalse(cfg["integration"]["telegram_buttons_enabled"])
        self.assertFalse(cfg["integration"]["modify_existing_publish_callbacks"])

    def test_david_silva_is_same_story(self):
        headline = (
            "David Silva vuelve al fútbol a los 40 años: tres años después de retirarse "
            "por una lesión de rodilla, ficha por el Supreme Sha Tin de Hong Kong."
        )
        trend = (
            "TT#6 David Silva es tendencia porque vuelve al fútbol a los 40 años, "
            "tres años después de retirarse, para fichar por el Supreme Sha Tin "
            "de la Premier League de Hong Kong."
        )
        result = classify_story_pair(headline, trend, subject="David Silva")
        self.assertEqual(result.classification, "same_story")

    def test_uco_is_same_story(self):
        headline = (
            "Un informe de la UCO recoge que una testigo declaró que un exjuez dijo "
            "que había que eliminar a la jueza Beatriz Biedma. Es una acusación no probada."
        )
        trend = (
            "TT#7 La UCO es tendencia porque un informe de la Guardia Civil recoge el "
            "testimonio de una mujer que afirma que un exjuez habló de eliminar a la "
            "jueza Beatriz Biedma, que investigó a David Sánchez."
        )
        result = classify_story_pair(headline, trend, subject="La UCO")
        self.assertEqual(result.classification, "same_story")

    def test_unrelated_items_remain_independent(self):
        news = "David Silva vuelve al fútbol y ficha por un club de Hong Kong."
        trend = "Can Xue lidera algunas apuestas para el Nobel de Literatura."
        result = classify_story_pair(news, trend)
        self.assertEqual(result.classification, "independent")


    def test_x_search_is_restricted_to_ttittulares(self):
        url = build_x_account_search_url(
            "@ttittulares",
            "David Silva vuelve al fútbol con el Supreme Sha Tin",
        )
        self.assertIn("from%3Attittulares", url)
        self.assertIn("David", url)
        self.assertIn("Silva", url)

    def test_x_search_is_restricted_to_ttendenciasesp(self):
        url = build_x_account_search_url(
            "@ttendenciasesp",
            "La UCO Beatriz Biedma",
        )
        self.assertIn("from%3Attendenciasesp", url)
        self.assertIn("UCO", url)


if __name__ == "__main__":
    unittest.main()
