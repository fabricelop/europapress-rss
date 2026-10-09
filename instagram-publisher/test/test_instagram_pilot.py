import io
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
from shared.instagram_pilot import enabled, caption, materialize, attach_button


def png_rgba(width=1254,height=1254):
    b=io.BytesIO()
    Image.new("RGBA",(width,height),(12,33,155,128)).save(b,"PNG")
    return b.getvalue()


class InstagramPilotTests(unittest.TestCase):
    def test_disabled_by_default(self):
        with patch.dict(os.environ,{"INSTAGRAM_PILOT_ENABLED":""}):
            self.assertFalse(enabled())
            keyboard={"inline_keyboard":[[{"text":"✅ Publicado","callback_data":"tt:p:abc123"}]]}
            self.assertEqual(attach_button(keyboard,"tt:i:abc123",{"image_url":"abc.jpg"}),keyboard)

    def test_button_independent_of_x(self):
        keyboard={"inline_keyboard":[[{"text":"📋 Copiar","copy_text":{"text":"base"}}],
                                    [{"text":"🗑 Desestimar","callback_data":"tt:d:abc123"},
                                     {"text":"✅ Publicado","callback_data":"tt:p:abc123"}]]}
        with patch.dict(os.environ,{"INSTAGRAM_PILOT_ENABLED":"1"}):
            result=attach_button(keyboard,"tt:i:abc123",{"image_url":"https://example.com/ai.jpg"})
        self.assertEqual(len(result["inline_keyboard"]),3)
        self.assertEqual(result["inline_keyboard"][-1],keyboard["inline_keyboard"][-1])
        self.assertEqual(result["inline_keyboard"][-2][0]["callback_data"],"tt:i:abc123")
        self.assertEqual(len(keyboard["inline_keyboard"]),2)

    def test_same_trends_contract(self):
        keyboard={"inline_keyboard":[[{"text":"Publicado","callback_data":"tx:p:abc123:2"}]]}
        with patch.dict(os.environ,{"INSTAGRAM_PILOT_ENABLED":"1"}):
            result=attach_button(keyboard,"tx:i:abc123:2",{"image_url":"ai.jpg"})
        self.assertEqual(result["inline_keyboard"][0][0]["callback_data"],"tx:i:abc123:2")

    def test_delivery_workflows_keep_explicit_manual_pilot_default(self):
        root=pathlib.Path(__file__).resolve().parents[2]
        for relative in (
            ".github/workflows/send-ttittulares-ready-telegram.yml",
            ".github/workflows/send-ttendencias-explained-telegram.yml",
            ".github/workflows/refresh-ttittulares-telegram-keyboard.yml",
        ):
            text=(root/relative).read_text(encoding="utf8")
            self.assertIn("INSTAGRAM_PILOT_ENABLED: ${{ vars.INSTAGRAM_PILOT_ENABLED || '1' }}",text)
            self.assertNotIn("/media_publish",text)
        ready=(root/".github/workflows/send-ttittulares-ready-telegram.yml").read_text(encoding="utf8")
        self.assertIn("if current:",ready)
        self.assertIn("edit_keyboard(int(current.get",ready)
        self.assertIn('patches["instagram"]=instagram_post',ready)

    def test_shakira_audit_makes_no_instagram_publish_request(self):
        root=pathlib.Path(__file__).resolve().parents[2]
        workflow=(root/".github/workflows/instagram-shakira-readonly-audit.yml").read_text(encoding="utf8")
        self.assertIn("SELECT state,media_id,permalink",workflow)
        self.assertIn("ttendencias:3ff255e46d90",workflow)
        self.assertIn("/meta-preflight",workflow)
        self.assertNotIn("/publish",workflow)
        self.assertNotIn("/media_publish",workflow)

    def test_png_converted_to_real_jpeg(self):
        with tempfile.TemporaryDirectory() as root:
            data=materialize(root,"ttittulares","abc123",2,png_rgba())
            self.assertIn("/ttittulares/instagram-images/",data["image_url"])
            p=pathlib.Path(root)/data["image_local_path"]
            self.assertTrue(p.exists())
            with Image.open(p) as image:
                self.assertEqual(image.format,"JPEG")
                self.assertEqual(image.mode,"RGB")
                self.assertEqual(image.size,(1254,1254))
            self.assertEqual(data,materialize(root,"ttittulares","abc123",2,png_rgba()))

    def test_letterbox_tall_image(self):
        with tempfile.TemporaryDirectory() as root:
            data=materialize(root,"trends","abc123",0,png_rgba(800,1450))
            with Image.open(pathlib.Path(root)/data["image_local_path"]) as image:
                self.assertGreaterEqual(image.width/image.height,0.8-0.002)

    def test_caption_preserves_approved_text_without_redundant_footer(self):
        output=caption("Exacto.\n🌶️ Chiste.")
        self.assertTrue(output.startswith("Exacto.\n🌶️ Chiste."))
        self.assertNotIn("generada con IA",output)
        self.assertIn("#Actualidad",output)
        with self.assertRaises(ValueError):
            caption("x"*2201)

    def test_bad_image_and_identity_blocked(self):
        with tempfile.TemporaryDirectory() as root:
            for path in ("../../secrets","other"):
                with self.assertRaises(ValueError):
                    materialize(root,path,"abc123",1,png_rgba())
            with self.assertRaises(ValueError):
                materialize(root,"trends","../secrets",1,png_rgba())
            with self.assertRaises(Exception):
                materialize(root,"trends","abc123",1,b"garbage"*1000)


if __name__=="__main__":
    unittest.main()
