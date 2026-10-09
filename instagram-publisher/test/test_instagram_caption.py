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
        self.assertLessEqual(result.count("#"), 5)

    def test_no_brand_prefix_or_redundant_ai_footer(self):
        result = caption("ttactualidad: Noticia sobre vivienda y desahucios.\n\n"
                         "Ilustración satírica generada con IA.\n#TTActualidad")
        self.assertTrue(result.startswith("Noticia sobre vivienda"))
        self.assertNotIn("Ilustración satírica", result)
        self.assertNotIn("#TTActualidad", result)
        self.assertIn("#Vivienda", result)


    def test_trump_has_five_topical_tags(self):
        source = ("Trump dice que EEUU no atacará Irán antes de las legislativas del 3 de noviembre "
                  "y mantiene el bloqueo. El anuncio llega con el precio de los combustibles "
                  "en el centro del debate.\n\n🌶️ El calendario electoral acaba de entrar en la sala de guerra.")
        output=caption(source)
        self.assertTrue(output.startswith(source))
        self.assertEqual(output.split("\n\n")[-1], "#DonaldTrump #EstadosUnidos #Iran #Elecciones #Combustibles")
        self.assertNotIn("#Actualidad", output)

    def test_renoir_has_arts_hashtags(self):
        source=("Francia recupera los dos Renoir robados en septiembre del museo de Cagnes-sur-Mer "
                "y detiene a seis personas. Las obras, del Museo de Orsay, estaban cedidas.\n\n"
                "🌶️ El golpe impresionista acabó enmarcado por la policía.")
        output=caption(source)
        self.assertEqual(output.split("\n\n")[-1], "#Renoir #Francia #Arte #Museos")
        self.assertNotIn("#Actualidad", output)

    def test_nobel_paz_has_evidence_based_tags(self):
        source=("TT#15 Premio Nobel de la Paz 2026 es tendencia porque la jurista sudafricana "
                "Navi Pillay ha ganado el galardón por promover la paz y el derecho internacional.\n"
                "🌶️ Oslo ha puesto toga a la paloma de la paz.")
        output=caption(source)
        self.assertEqual(output.split("\n\n")[-1],
                         "#PremioNobelDeLaPaz #NaviPillay #Sudafrica #DerechoInternacional #Paz")
        self.assertNotIn("#Actualidad", output)

    def test_removes_account_handle_and_stale_generic_tag(self):
        output=caption("ttactualidad: La cultura del arte crece en Francia.\n\n#Actualidad")
        self.assertFalse(output.lower().startswith("ttactualidad"))
        self.assertNotIn("#Actualidad", output)
        self.assertIn("#Arte", output)
        self.assertIn("#Francia", output)

    def test_unrelated_people_are_not_tagged(self):
        result = caption("Una noticia sin nombres propios ni categorías fáciles.")
        self.assertEqual(result, "Una noticia sin nombres propios ni categorías fáciles.")
        self.assertIn("#Shakira", result)
        self.assertNotIn("#Actualidad", result)

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

    def test_maximum_five_tags_total_including_inlined(self):
        result = caption("#LaRevuelta #Actualidad #Musica #Television Shakira llega a la entrevista.")
        self.assertLessEqual(result.count("#"), 5)
        self.assertIn("#Shakira", result)
        self.assertNotIn("#Actualidad", result)


if __name__ == "__main__":
    unittest.main()
