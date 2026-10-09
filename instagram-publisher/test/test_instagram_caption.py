"""Instagram post captions, independent of Telegram and X editorial text."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from shared.instagram_pilot import caption


class CaptionTests(unittest.TestCase):
    def test_shakira_uses_subject_tags_and_existing_trend_tag_once(self):
        source = (
            "TT#5 #LaRevuelta es tendencia porque Shakira protagoniza hoy un especial: "
            "Broncano y el equipo salen del Teatro Albéniz para entrevistarla.\n"
            "🌶️ La invitada se hizo tanto de rogar que el plató acabó yendo a buscarla."
        )
        result = caption(source)
        self.assertTrue(result.startswith("TT#5 #LaRevuelta"))
        self.assertEqual(result.count("#LaRevuelta"), 1)
        self.assertIn("#Shakira", result)
        self.assertIn("#DavidBroncano", result)
        self.assertNotIn("Ilustración satírica", result)
        self.assertNotIn("#TTActualidad", result)
        self.assertEqual(result.split("\n\n")[-1], "#Shakira #DavidBroncano")

    def test_real_madrid_uses_sport_specific_tags(self):
        source = (
            "El Real Madrid logra su primera victoria en la Euroliga tras vencer 86-76 al Partizán.\n\n"
            "🌶️ El Madrid estrenó el casillero justo cuando ya empezaba a parecer decorativo."
        )
        result = caption(source)
        self.assertIn("#RealMadrid", result)
        self.assertIn("#Euroliga", result)
        self.assertIn("#Baloncesto", result)
        self.assertFalse(result.lower().startswith("ttactualidad"))
        self.assertLessEqual(result.count("#"), 4)

    def test_no_brand_prefix_or_redundant_ai_footer(self):
        result = caption("ttactualidad: Noticia sobre vivienda y desahucios.\n\n"
                         "Ilustración satírica generada con IA.\n#TTActualidad")
        self.assertTrue(result.startswith("Noticia sobre vivienda"))
        self.assertNotIn("Ilustración satírica", result)
        self.assertNotIn("#TTActualidad", result)
        self.assertIn("#Vivienda", result)

    def test_unrelated_people_are_not_tagged(self):
        result = caption("Una noticia sin nombres propios ni categorías fáciles.")
        self.assertEqual(result, "Una noticia sin nombres propios ni categorías fáciles.\n\n#Actualidad")
        self.assertNotIn("#Shakira", result)

    def test_approved_text_remains_verbatim_and_only_hashtags_are_appended(self):
        source = "Una sentencia judicial condena a tres hombres.\n🌶️ El modo avión llegó por orden del juez."
        result = caption(source)
        self.assertTrue(result.startswith(source))
        self.assertIn("#Justicia", result)

    def test_very_long_caption_preserves_editorial_text_without_tags(self):
        result = caption("A" * 2199)
        self.assertEqual(len(result), 2199)
        with self.assertRaises(ValueError):
            caption("A" * 2201)

    def test_maximum_four_tags_total_including_inlined(self):
        result = caption("#LaRevuelta #Actualidad #Musica #Television Shakira llega a la entrevista.")
        self.assertLessEqual(result.count("#"), 4)
        self.assertNotIn("#Shakira", result)


if __name__ == "__main__":
    unittest.main()
