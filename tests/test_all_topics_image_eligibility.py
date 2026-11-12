"""ImageGen eligibility is topic-neutral; approval stays with the editor."""
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class TopicNeutralImageEligibility(unittest.TestCase):
    def test_news_has_no_content_veto(self):
        from ttittulares import auto_listas_images as images
        policy = json.loads((ROOT / "ttittulares/auto_listas_images_policy.json").read_text())
        row = {"event_id": "test999", "revision": 1, "title": "Noticia explicada",
               "prepared_at": "2026-11-12T14:45:00Z",
               "tweet": {"text": "Texto factual", "remate": "Remate"},
               "with_image": False, "disable_ai_image": True,
               "image_mode": "fallback_only", "sensitive_editorial": True,
               "ai_image_status": "disabled"}
        self.assertTrue(images.main_story(row, set(), set(), policy)[0])
        job, _ = images.make_job(row)
        self.assertEqual(job["delivery_mode"], "launch_only")
        self.assertIn("nunca publicar, aprobar", job["instructions"]["lifecycle"])
        row["ai_image_tool_called_at"] = "2026-11-12T14:45:00Z"
        self.assertFalse(images.main_story(row, set(), set(), policy)[0])

    def test_trends_all_topics_and_tremending(self):
        config = json.loads((ROOT / "trends/editorial-config.json").read_text())
        p = config["editorial"]["image_policy"]
        self.assertTrue(p["always_generate"])
        self.assertEqual(p["sensitive_mode"], "ai_plus_fallback")
        self.assertFalse(p["sensitive_sets_disable_ai_image"])
        self.assertIn("Tremending", p["queue_instruction"])
        run = (ROOT / "vercel-webhook/lib/ttendencias-run-handler.js").read_text()
        assert "const blocked=Boolean(row.tremending_origin)" not in run
        self.assertIn("eligible:!archived", run)
        self.assertIn("La aprobación posterior pertenece exclusivamente al editor", run)
        control = (ROOT / "vercel-webhook/lib/ttendencias-control-handler.js").read_text()
        self.assertNotIn("if (row.tremending_origin) continue;", control)
        self.assertIn("req.disable_ai_image = false;", control)
        self.assertIn('req.image_strategy = "ai_plus_fallback";', control)
        editorial = (ROOT / "trends/apply_editorial_outbox.py").read_text()
        self.assertIn('"with_image": True,', editorial)
        self.assertIn('"ai_image_status": "pending",', editorial)
        self.assertIn('"image_pending": True,', editorial)
        self.assertNotIn('"with_image": bool(req.get("with_image"))', editorial)

if __name__ == "__main__":
    unittest.main()
