import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

SCRIPT=Path(__file__).resolve().parents[1]/"shared"/"telegram_readonly_delivery.py"
spec=importlib.util.spec_from_file_location("tti_delivery_under_test",SCRIPT)
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class AuthenticTitleTests(unittest.TestCase):
    def test_generic_titles_rejected(self):
        for title in ("Noticia","Sin título","Actualidad","Titular pendiente",""):
            self.assertEqual(module.authentic_news_title(title),"")

    def test_processing_title_recovered_from_queue_and_no_photo_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for folder in ("telegram","ttittulares"):(root/folder).mkdir()
            now=datetime.now(timezone.utc)
            start=now.isoformat()
            def write(name,doc):
                (root/name).write_text(json.dumps(doc),encoding="utf-8")
            write("telegram/editorial-processing.json",{"items":[{"event_id":"abc","title":"Noticia","status":"PROCESSING","selected_at":start}]})
            write("ttittulares/editorial-queue.json",{"items":[{"event_id":"abc","title":"Titular RSS auténtico","url":"https://example.com/noticia"}]})
            write("ttittulares/prepared.json",{"items":[]})
            write("ttittulares/decisions.json",{"items":[]})
            with patch.object(module,"ROOT",root):
                cards=list(module.news_cards(now))
                self.assertEqual(len(cards),1)
                self.assertIn("Titular RSS auténtico",cards[0]["text"])
                self.assertFalse(cards[0]["final"])
                self.assertEqual(cards[0]["image"],"")
                self.assertEqual(cards[0]["source_url"],"https://example.com/noticia")
                write("ttittulares/editorial-queue.json",{"items":[{"event_id":"abc","title":"Noticia"}]})
                self.assertEqual(list(module.news_cards(now)),[])

if __name__=="__main__":unittest.main()
