"""Non-publishing SEO pilot contract tests; stdlib-only: python3 -m unittest discover -s seo-prep/ttactualidad."""
import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_seo as seo


def fixture(name="Golden Boy", ident="c767f00460c3", revision=0):
    return {
        "status": "EXPLICADA", "name": name, "editorial_id": ident,
        "revision": revision, "rank": 7,
        "explanation": "TT#7 Golden Boy es tendencia porque se anunció un premio.\n#Deporte\nUn remate.",
        "explained_at": "2026-11-09T18:12:00+01:00",
        "last_reviewed_at": "", "closer_text": "Un remate.",
        "verification_sources": ["https://ejemplo.test/noticia"],
    }


class SeoPrepTests(unittest.TestCase):
    def test_pilot_has_real_identity_sources_and_original_text(self):
        p = seo.candidate(fixture())
        self.assertEqual(p["editorial_id"], "c767f00460c3")
        self.assertEqual(p["revision"], 0)
        self.assertEqual(p["explanation_verbatim"], fixture()["explanation"])
        self.assertEqual(p["date_published"], "2026-11-09T18:12:00+01:00")
        self.assertEqual(p["sources"], ["https://ejemplo.test/noticia"])
        self.assertEqual(p["structured_data_CANDIDATE_NOT_PUBLISHED"]["@type"], "Article")
        self.assertIn("c767f00460c3", p["proposed_path"])

    def test_same_episode_revision_keeps_permanent_proposed_url(self):
        a = seo.candidate(fixture(revision=0))
        b = seo.candidate(fixture(revision=2))
        self.assertEqual(a["proposed_path"], b["proposed_path"])
        other = seo.candidate(fixture(ident="deadbeef2233"))
        self.assertNotEqual(a["proposed_path"], other["proposed_path"])

    def test_unexplained_and_source_less_cannot_be_published_as_previews(self):
        for change in (
            {"status": "PENDIENTE"},
            {"editorial_id": ""},
            {"explained_at": ""},
            {"verification_sources": []},
            {"verification_sources": ["javascript:alert(1)"]},
            {"revision": -1},
        ):
            self.assertIsNone(seo.candidate({**fixture(), **change}), change)

    def test_hash_tags_accents_and_escaping(self):
        p = seo.candidate(fixture(name="#ElSótano09N<script>alert(1)</script>"))
        self.assertTrue(p["proposed_path"].startswith("/tendencias/elsotano09n-script-"))
        self.assertIn("noindex,nofollow", seo.preview_page(p, False))
        self.assertNotIn("<script>alert(1)</script>", seo.preview_page(p, False))
        self.assertIn("radar de la instantánea no estaba verificado", seo.preview_page(p, False))
        self.assertNotIn('rel="canonical"', seo.preview_page(p, False))
        self.assertNotIn('type="application/ld+json"', seo.preview_page(p, False))

    def test_offline_generation_never_claims_deployment(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "top30.json"
            source.write_text(json.dumps({
                "generated_at": "2026-11-09T18:00:00Z",
                "radar_live_verified": False,
                "items": [fixture(), fixture(name="#TEM9N", ident="aabbccdd0011")],
            }, ensure_ascii=False), encoding="utf-8")
            result = seo.build(source, root / "draft", names=("Golden Boy",), limit=1)
            self.assertEqual(result["status"], "DRAFT_ONLY_NEVER_DEPLOYED")
            self.assertFalse(result["source_radar_live_verified"])
            self.assertEqual(len(result["pages"]), 1)
            self.assertTrue((root / "draft" / "previews" / "c767f00460c3.html").exists())
            self.assertFalse((root / "draft" / "sitemap.xml").exists())
            self.assertNotIn("<link rel=\"canonical\"", (root / "draft" / "previews" / "c767f00460c3.html").read_text())
            self.assertFalse(any(x.suffix == ".xml" for x in (root / "draft").rglob("*")))

    def test_default_names_safe_fallback_when_not_present(self):
        pages = seo.pick_pages([fixture(name="Otra", ident="1234567890ab")],
                               seo.DEFAULT_PILOT, 5, seo.CANONICAL_SITE)
        self.assertEqual(len(pages), 1)
        self.assertEqual(pages[0]["name"], "Otra")


if __name__ == "__main__":
    unittest.main()
