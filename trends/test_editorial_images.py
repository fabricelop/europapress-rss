"""Regression tests for interrupted image delivery; never writes live state."""
import base64
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from PIL import Image

spec = importlib.util.spec_from_file_location("apply", Path(__file__).with_name("apply_editorial_outbox.py"))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class ImageRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        app.TRENDS = Path(self.tmp.name)
        app.OUTBOX = app.TRENDS / "editorial-outbox"
        app.OUTBOX.mkdir()
        app.save(app.TRENDS / "requests.json", {"requests": [
            {"id": key, "name": key, "revision": 0, "status": "preparing"}
            for key in ("first", "second")
        ]})

    def image(self, size=(1024, 1024)):
        # Synthetic pixel noise is only a validator fixture, never editorial art.
        im = Image.effect_noise(size, 60).convert("RGB")
        buf = io.BytesIO()
        im.save(buf, "PNG")
        self.assertGreater(len(buf.getvalue()), 350000)
        checks = "reviewed_after_generation single_narrative_scene visual_gag_without_text no_infographic_layout no_diagram_arrows_or_connectors no_ui_or_scoreboard_layout low_text depth_lighting_texture".split()
        return {"url": "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode(),
                "generated": True, "rights_status": "generated", "source": "TTendencias / ChatGPT",
                "style_version": "editorial-scene-v2-cleveland", "style_check": dict.fromkeys(checks, True)}

    def payload(self, key="first", image=True):
        return {"id": key, "revision": 0, "status": "ready", "prepared_item": {
            "id": key, "primary": {"text": "Verified test"},
            "alternatives": [{"tweet_text": "Alternative"} for _ in range(3)],
            **({"image": self.image()} if image else {})}}

    def test_checkpoint_then_resume_without_image_bytes(self):
        app.save(app.OUTBOX / "first-r0.json", {"id": "first", "revision": 0,
                 "status": "image_checkpoint", "image": self.image()})
        self.assertEqual(app.main(), 0)
        cache = app.TRENDS / "image-cache/first-r0.json"
        self.assertTrue(cache.exists())
        self.assertEqual(app.load(app.TRENDS / "prepared.json", {})["items"], [])
        app.save(app.OUTBOX / "first-r0.json", self.payload(image=False))
        self.assertEqual(app.main(), 0)
        ready = app.load(app.TRENDS / "prepared.json", {})["items"][0]
        self.assertTrue(ready["image"]["url"].endswith("first-r0.jpg"))
        self.assertLess((app.TRENDS / "generated-images/first-r0.jpg").stat().st_size, 350000)

    def test_text_failure_preserves_image_and_other_item(self):
        bad = self.payload()
        bad["prepared_item"]["alternatives"] = []
        app.save(app.OUTBOX / "first-r0.json", bad)
        app.save(app.OUTBOX / "second-r0.json", self.payload("second"))
        self.assertEqual(app.main(), 1)
        self.assertTrue((app.TRENDS / "image-cache/first-r0.json").exists())
        self.assertEqual([x["id"] for x in app.load(app.TRENDS / "prepared.json", {})["items"]], ["second"])
        fixed = app.load(app.OUTBOX / "first-r0.json", {})
        self.assertTrue(fixed["prepared_item"]["image"]["url"].startswith("https://raw."))
        fixed["prepared_item"]["alternatives"] = [{"tweet_text": "Fixed"}] * 3
        app.save(app.OUTBOX / "first-r0.json", fixed)
        self.assertEqual(app.main(), 0)

    def test_corrupt_image_is_rejected(self):
        payload = self.payload()
        payload["prepared_item"]["image"]["url"] = "data:image/jpeg;base64,YmFk"
        app.save(app.OUTBOX / "first-r0.json", payload)
        self.assertEqual(app.main(), 1)
        self.assertFalse((app.TRENDS / "image-cache/first-r0.json").exists())

    def test_portrait_normalization_respects_minimum_width(self):
        item = {"image": self.image((768, 1152))}
        app.materialize_inline_generated_image(item, "first", 0)
        app.validate_generated_image(item)
        with Image.open(app.TRENDS / "generated-images/first-r0.jpg") as im:
            self.assertEqual(im.size, (480, 720))

    def test_obsolete_revision_and_dismissed_are_not_revived(self):
        for status, revision in (("dismissed", 0), ("preparing", 1)):
            app.save(app.TRENDS / "requests.json", {"requests": [{"id": "first", "revision": revision, "status": status}]})
            app.save(app.OUTBOX / "first-r0.json", self.payload())
            self.assertEqual(app.main(), 0)
            self.assertEqual(app.load(app.TRENDS / "prepared.json", {})["items"], [])


if __name__ == "__main__":
    unittest.main()
