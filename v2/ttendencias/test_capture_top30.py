import unittest
from v2.ttendencias.capture_top30 import capture


def page(count=30):
    rows = "".join(
        f'<tr><td>{i}</td><td><a href="/es/spain/">Termino {i}</a></td></tr>'
        for i in range(1, count + 1)
    )
    return f'<html><h1>Twitter trends in Spain</h1><table class="ranking trends">{rows}</table></html>'


class CaptureTests(unittest.TestCase):
    def test_exact_thirty_ranked(self):
        result = capture(page(), observed_at="2026-11-12T22:00:00Z")
        self.assertEqual(result["count"], 30)
        self.assertEqual(result["top30"][0], "Termino 1")
        self.assertEqual(result["top30"][-1], "Termino 30")
        self.assertFalse(result["verified_against_x"])

    def test_refuse_incomplete(self):
        with self.assertRaises(ValueError):
            capture(page(29))

    def test_refuse_conflicting_rank(self):
        html = page() .replace("</table>", '<tr><td>4</td><td>Otro</td></tr></table>')
        with self.assertRaises(ValueError):
            capture(html)

    def test_refuse_foreign_country_metadata(self):
        html = page().replace("<html>", '<html><meta name="geo.country" content="FR">')
        with self.assertRaises(ValueError):
            capture(html)


if __name__ == "__main__":
    unittest.main()
