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

    def _fixture(self, root, eid, title="Noticia", with_radar=True):
        for folder in ("telegram", "ttittulares"):
            (root/folder).mkdir(exist_ok=True)
        now = datetime.now(timezone.utc)
        self._write(root, "telegram/editorial-processing.json", {
            "items":[{"event_id":eid,"status":"PROCESSING","title":title,
                      "selected_at":now.isoformat(),"revision":1}]})
        self._write(root, "ttittulares/prepared.json", {"items":[]})
        self._write(root, "ttittulares/decisions.json", {"items":[]})
        self._write(root, "ttittulares/editorial-queue.json", {"items":[]})
        self._write(root, "telegram/events.json", {"events":[{
            "id":eid,"canonical_title":"Titular RSS de Ceuta",
            "url":"https://example.org/ceuta",
            "appearances":[{"source":"laSexta","title":"Titular RSS de Ceuta",
                            "url":"https://example.org/ceuta"}]
        }]} if with_radar else {"events":[]})
        return now

    def _write(self, root, path, data):
        (root/path).write_text(json.dumps(data),encoding="utf-8")

    def test_missing_real_headline_never_calls_telegram(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            now=self._fixture(root,"unknown",with_radar=False)
            with patch.object(module,"ROOT",root), patch.object(module,"send") as sent:
                self.assertEqual(module.process("ttittulares",now,"fake","fake"),(0,0))
                sent.assert_not_called()
                self.assertEqual(list(module.news_cards(now)),[])

    def test_radar_recovery_edits_existing_anonymous_telegram_card(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            now=self._fixture(root,"ceuta")
            self._write(root,"telegram/ttittulares-deliveries.json",{"items":[{
                "event_id":"ceuta","revision":1,"status":"sent",
                "title":"Noticia","telegram_message_id":3466,"final":False,
                "delivered_at":now.isoformat(),"content_sha256":"old"}]})
            with patch.object(module,"ROOT",root), patch.object(module,"send",return_value={"message_id":3466}) as send, patch.object(module,"fast_archive_from_article",return_value=""):
                self.assertEqual(module.process("ttittulares",now,"fake","fake"),(0,1))
                self.assertEqual(send.call_args.args[1],"editMessageText")
                self.assertEqual(send.call_args.args[2]["message_id"],3466)
                self.assertEqual(
                    send.call_args.args[2]["text"],
                    "🟠 EN ELABORACIÓN\n\nTitular RSS de Ceuta")
                self.assertNotIn("Fuente:",send.call_args.args[2]["text"])
                self.assertNotIn("https://example.org/ceuta",send.call_args.args[2]["text"])
                self.assertTrue(send.call_args.args[2]["reply_markup"]["inline_keyboard"])
                self.assertEqual(
                    send.call_args.args[2]["reply_markup"]["inline_keyboard"][-1][0]["text"],
                    "🗑️ Borrar")
                rows=module.load("telegram/ttittulares-deliveries.json",{})["items"]
                self.assertEqual(len(rows),1)
                self.assertEqual(rows[0]["title"],"Titular RSS de Ceuta")
                self.assertEqual(rows[0]["source_url"],"https://example.org/ceuta")
                send.reset_mock()
                self.assertEqual(module.process("ttittulares",now,"fake","fake"),(0,0))
                send.assert_not_called()

    def test_earlier_deleted_story_keeps_other_telegram_message_for_editorial(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            now=self._fixture(root,"ceuta")
            self._write(root,"telegram/ttittulares-deliveries.json",{"items":[{
                "event_id":"prior","status":"deleted","title":"Titular RSS de Ceuta",
                "source_url":"https://example.org/ceuta","telegram_message_id":3364,
                "delivered_at":now.isoformat()
            },{
                "event_id":"ceuta","status":"sent","title":"Noticia",
                "telegram_message_id":3466,"final":False,
                "delivered_at":now.isoformat()
            }]})
            with patch.object(module,"ROOT",root), patch.object(module,"send",return_value={"message_id":3466}) as send:
                self.assertEqual(module.process("ttittulares",now,"fake","fake"),(0,1))
                self.assertEqual(send.call_args.args[1],"editMessageText")
                self.assertEqual(send.call_args.args[2]["message_id"],3466)
                self.assertEqual(module.load("telegram/ttittulares-deliveries.json",{})["items"][1]["status"],"sent")
                send.reset_mock()
                self.assertEqual(module.process("ttittulares",now,"fake","fake"),(0,0))
                send.assert_not_called()

    def test_own_deleted_news_never_resurrected(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            now=self._fixture(root,"ceuta",title="Titular RSS de Ceuta")
            self._write(root,"ttittulares/decisions.json",{
                "items":[{"event_id":"ceuta","status":"deleted"}]})
            with patch.object(module,"ROOT",root), patch.object(module,"send") as send:
                self.assertEqual(module.process("ttittulares",now,"fake","fake"),(0,0))
                send.assert_not_called()

    def test_provisional_draft_is_labeled_unverified(self):
        copy=module.provisional_news_copy({"verified_source_count":0,
                                            "factual_summary":"Detalles no comprobados"},
                                           "Titular auténtico")
        self.assertIn("VERIFICACIÓN",copy)
        self.assertNotIn("Detalles no comprobados",copy)


    def test_other_source_cannot_resend_robbery_after_delete(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            now=self._fixture(root,"antony-second",
                title="Antony, víctima de un robo en su casa durante el Betis - Oporto",
                with_radar=False)
            self._write(root,"telegram/ttittulares-deliveries.json",{"items":[{
                "event_id":"antony-first","revision":1,"status":"deleted",
                "title":"Roban en la casa de Antony durante el Betis-Oporto",
                "telegram_message_id":4200,"delivered_at":now.isoformat()}]})
            with patch.object(module,"ROOT",root), patch.object(module,"send") as sender:
                self.assertEqual(module.process("ttittulares",now,"token","chat"),(0,0))
                sender.assert_not_called()
                rows=module.load("telegram/ttittulares-deliveries.json",{})["items"]
                self.assertEqual(len(rows),1)
                self.assertEqual(rows[0]["status"],"deleted")

    def test_two_ids_same_fact_in_one_batch_send_once(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/"telegram").mkdir()
            (root/"ttittulares").mkdir()
            now=datetime.now(timezone.utc)
            start=now.isoformat()
            self._write(root,"telegram/editorial-processing.json",{"items":[
                {"event_id":"fort-hood","status":"PROCESSING","revision":1,
                 "title":"Trump dice que el fusilamiento del condenado de Fort Hood no será retransmitido en streaming",
                 "selected_at":start},
                {"event_id":"nidal-hasan","status":"PROCESSING","revision":1,
                 "title":"Trump dice que la ejecución de Nidal Hasan no será transmitida en directo",
                 "selected_at":start}]})
            self._write(root,"ttittulares/prepared.json",{"items":[]})
            self._write(root,"ttittulares/decisions.json",{"items":[]})
            self._write(root,"telegram/ttittulares-deliveries.json",{"items":[]})
            # In production active_entries is a separate list after baseline.
            self._write(root,"telegram/lifecycle-baseline.json",{
                "activated_at":"2026-10-12T15:25:23Z",
                "project_state":{"ttittulares":{"historic_max_message_id":3559}}})
            mids=iter((5001,5002))
            with patch.object(module,"ROOT",root), patch.object(module,"send",
                              side_effect=lambda *args,**kwargs:{"message_id":next(mids)}) as sender:
                self.assertEqual(module.process("ttittulares",now,"token","chat"),(1,0))
                self.assertEqual(sender.call_count,1)
                rows=module.load("telegram/ttittulares-deliveries.json",{})["items"]
                self.assertEqual(len(rows),1)
                self.assertEqual(rows[0]["telegram_message_id"],5001)
                self.assertEqual(module.process("ttittulares",now,"token","chat"),(0,0))
                self.assertEqual(sender.call_count,1)

    def test_new_contradictory_decision_is_not_a_duplicate(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            now=self._fixture(root,"new-junta",
                title="La Junta Electoral rechaza investigar a Sánchez por la rueda de prensa en La Moncloa",
                with_radar=False)
            self._write(root,"telegram/ttittulares-deliveries.json",{"items":[{
                "event_id":"old-junta","revision":1,"status":"deleted",
                "title":"La Junta Electoral abre expediente sancionador a Sánchez por la rueda de prensa en La Moncloa",
                "telegram_message_id":4202,"delivered_at":now.isoformat()}]})
            with patch.object(module,"ROOT",root), patch.object(module,"send",
                              return_value={"message_id":4203}) as sender:
                self.assertEqual(module.process("ttittulares",now,"token","chat"),(1,0))
                self.assertEqual(sender.call_count,1)
                rows=module.load("telegram/ttittulares-deliveries.json",{})["items"]
                self.assertEqual(len(rows),2)
                self.assertEqual(rows[0]["status"],"deleted")
                self.assertEqual(rows[1]["event_id"],"new-junta")

if __name__=="__main__":unittest.main()
