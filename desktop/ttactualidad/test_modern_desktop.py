"""Modern Windows presentation and direct GitHub authentication tests (offline)."""
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import unittest
from unittest.mock import patch

os.environ["QT_QPA_PLATFORM"]="offscreen"
from PySide6.QtWidgets import QApplication

ROOT=pathlib.Path(__file__).resolve().parent
loader=importlib.machinery.SourceFileLoader("TTActualidad_Moderno",str(ROOT/"TTActualidad_Moderno.pyw"))
spec=importlib.util.spec_from_loader(loader.name,loader)
appmod=importlib.util.module_from_spec(spec)
loader.exec_module(appmod)

class DesktopModernTests(unittest.TestCase):
    def test_covered_card_is_recognizable_removable_and_not_publishable(self):
        row={'project':'ttendencias','id':'covered','revision':1,'state':'Listas',
             'title':'Adif','body':'Texto original que se conserva','category':'Tendencias',
             'source':'','image':'','covered_by_id':'joint','covered_by_name':'Investigación ferroviaria'}
        self.window.trends=[row]
        self.window.select_item(row,load_image=False)
        self.assertIn('AGRUPADA EN',self.window.state_tag.text())
        self.assertIn('Investigación ferroviaria',self.window.state_tag.text())
        self.assertFalse(self.window.actions['x'].isEnabled())
        self.assertFalse(self.window.actions['published'].isEnabled())
        self.assertTrue(self.window.actions['deleted'].isEnabled())
        self.assertIn('Texto original',self.window.body.toPlainText())

    def test_group_button_requests_editorial_review_without_rewriting_local_cards(self):
        from PySide6.QtWidgets import QMessageBox
        row={'project':'ttendencias','id':'first','revision':1,'state':'Listas',
             'title':'Adif','body':'Texto conservado','category':'Tendencias','source':'','image':''}
        self.window.trends=[row,dict(row,id='second')]
        with patch.object(appmod,'session_token',return_value='fake'), \
             patch.object(appmod.QMessageBox,'question',return_value=QMessageBox.Yes), \
             patch.object(self.window,'submit') as send:
            self.window.group_listas(False)
        event,payload=send.call_args.args
        self.assertEqual(event,'ttactualidad_group_listas_v1')
        self.assertEqual(payload['decision'],'group_listas')
        self.assertEqual(self.window.trends[0]['body'],'Texto conservado')
        self.assertFalse(self.window.optimistic_hides)
        self.window.sending=True
        self.window.on_finished('submit',(payload['request_id'],None),None)
        self.assertFalse(self.window.sending)

    @classmethod
    def setUpClass(cls):
        cls.app=QApplication.instance() or QApplication([])
        cls.app.setStyle("Fusion")
        cls.app.setStyleSheet(appmod.STYLE)

    def setUp(self):
        self.window=appmod.MainWindow()
        self.addCleanup(self.window.close)

    def test_native_copy_gag_is_pure_image_for_news_and_trends(self):
        for project in ("ttittulares","ttendencias"):
            row={"project":project,"id":"test-gag","revision":1,"state":"Listas",
                 "rank":4,"title":"Factura y márgenes",
                 "body":"La empresa publicó sus resultados.\n\n#Empresa #Resultados\n🌶️ El balance pasó por caja.",
                 "category":"Noticias","source":"","image":""}
            self.window.select_item(row,load_image=False)
            self.window.copy_gag()
            prompt=QApplication.clipboard().text()
            for marker in ("GAG IA","SOLO IMAGEN","SIN NINGÚN TEXTO","franja inferior",
                           "CONTEXTO NO VISIBLE","Más gag, menos barroquismo","guindillas"):
                self.assertIn(marker,prompt)
            self.assertIn("El balance pasó por caja.",prompt)
            self.assertNotIn("TEXTO EXACTO CERRADO. NO LO REESCRIBAS",prompt)

    def test_native_copy_gag_sensitive_news_no_satire(self):
        row={"project":"ttittulares","id":"test-tragedia","revision":1,"state":"Listas",
             "title":"Accidente con víctimas",
             "body":"Un accidente ha dejado víctimas confirmadas.\n\n#Accidente #Víctimas\n🌶️ Respeto a las familias.",
             "category":"Noticias","source":"","image":""}
        self.window.select_item(row,load_image=False)
        self.window.copy_gag()
        prompt=QApplication.clipboard().text()
        self.assertIn("PERIODÍSTICA RIGUROSA Y RESPETUOSA",prompt)
        self.assertIn("sin humor",prompt)
        self.assertIn("SIN NINGÚN TEXTO",prompt)

    def test_layout_has_metric_cards_sidebar_and_actions(self):
        self.assertEqual(len(self.window.nav),9)
        self.assertEqual(len(self.window.metric_labels),5)
        self.assertIn("published_news",self.window.metric_labels)
        self.assertIn("published_trends",self.window.metric_labels)
        self.assertEqual(len(self.window.actions),14)
        self.assertIn("chatgpt",self.window.actions)
        self.assertIn("gag",self.window.actions)
        self.assertIn("hints",self.window.actions)
        self.assertFalse(self.window.actions["deleted"].isEnabled())
        self.assertFalse(self.window.actions["published"].isEnabled())

    def test_section_navigation_and_ready_controls(self):
        row={"project":"ttittulares","id":"n1","revision":1,"state":"Listas",
             "title":"Una noticia","body":"Texto probado","category":"Noticias","source":"","image":""}
        self.window.news=[row]
        self.window.change_section("Noticias · Listas")
        self.assertEqual(self.window.list_data(),[row])
        self.window.select_item(row)
        self.assertTrue(self.window.actions["deleted"].isEnabled())
        self.assertTrue(self.window.actions["published"].isEnabled())
        self.assertFalse(self.window.actions["discard"].isEnabled())
        self.assertFalse(self.window.actions["source"].isEnabled())
        self.window.change_section("Tendencias · Top 30")
        self.assertIsNone(self.window.selected)

    def test_in_progress_only_discard_and_no_publish(self):
        row={"project":"ttendencias","id":"t1","revision":2,"state":"En elaboración",
             "title":"Tendencia","body":"En curso","category":"Tendencias","source":"","image":""}
        self.window.select_item(row)
        self.assertTrue(self.window.actions["discard"].isEnabled())
        self.assertFalse(self.window.actions["deleted"].isEnabled())
        self.assertFalse(self.window.actions["published"].isEnabled())

    def test_auth_checks_github_user_without_phone(self):
        with patch.object(appmod,"request",return_value=(200,{"login":"example-user"})) as mocked:
            self.assertEqual(appmod.validate_token("github_pat_"+"x"*30),"example-user")
            self.assertEqual(mocked.call_args.kwargs["token"],"github_pat_"+"x"*30)

    def test_auth_rejects_short_and_whitespace(self):
        for token in ("", "x", "github_pat_ bad"):
            with self.assertRaises(ValueError):appmod.validate_token(token)

    def test_storage_uses_system_keyring_not_plaintext_config(self):
        with patch.object(appmod.keyring,"get_password",return_value=json.dumps({
            "auth_type":"personal_access_token","access_token":"github_pat_test"})):
            self.assertEqual(appmod.session_token(),"github_pat_test")

    def test_non_https_sources_cannot_open_from_cards(self):
        self.assertFalse(appmod.safe_url("file:///etc/passwd"))
        self.assertFalse(appmod.safe_url("javascript:alert(1)"))
        self.assertEqual(appmod.safe_url("https://example.org/test"),"https://example.org/test")

    def _ready(self,project,ident):
        return {"project":project,"id":ident,"revision":0,"state":"Listas",
                "title":"Ejemplo "+ident,"body":"Texto","category":"Noticias" if project=="ttittulares" else "Tendencias",
                "source":"","image":""}

    def test_separate_confirmed_news_and_trends_counters(self):
        self.window.published={"ttittulares":42,"ttendencias":37}
        self.window.render_list()
        self.assertEqual(self.window.metric_labels["published_news"].text(),"42")
        self.assertEqual(self.window.metric_labels["published_trends"].text(),"37")
        self.assertEqual(self.window.metric_subtitles["published_news"].text(),"Confirmadas en GitHub")

    def test_optimistic_yes_hides_immediately_but_does_not_falsely_count(self):
        item=self._ready("ttittulares","news-one")
        self.window.news=[item]
        self.window.published={"ttittulares":42,"ttendencias":37}
        self.window.change_section("Noticias · Listas")
        self.window.select_item(item,load_image=False)
        with patch.object(self.window.worker,"run") as worker:
            self.window.editorial_action("published",confirmed=True)
            worker.assert_called_once()
        self.assertEqual(self.window.list_count.text(),"0 elementos")
        self.assertEqual(self.window.metric_labels["news_ready"].text(),"0")
        self.assertEqual(self.window.metric_labels["published_news"].text(),"42")
        self.assertEqual(self.window.metric_subtitles["published_news"].text(),"+1 pendiente")
        self.assertEqual(len(self.window.pending_actions),1)

    def test_optimistic_no_hides_without_increment(self):
        item=self._ready("ttendencias","trend-two")
        self.window.trends=[item]
        self.window.change_section("Tendencias · Listas")
        self.window.select_item(item,load_image=False)
        with patch.object(self.window.worker,"run") as worker:
            self.window.editorial_action("deleted",confirmed=True)
            worker.assert_called_once()
        self.assertEqual(self.window.list_count.text(),"0 elementos")
        self.assertEqual(self.window.metric_subtitles["published_trends"].text(),"Confirmadas en GitHub")
        request=next(iter(self.window.pending_actions.values()))
        self.assertEqual(request["decision"],"deleted")

    def test_rollback_on_send_failure_restores_hidden_card(self):
        item=self._ready("ttittulares","news-failed")
        self.window.news=[item]
        self.window.change_section("Noticias · Listas")
        self.window.select_item(item,load_image=False)
        with patch.object(self.window.worker,"run"):
            self.window.editorial_action("published",confirmed=True)
        self.assertEqual(self.window.list_count.text(),"0 elementos")
        request_id=next(iter(self.window.pending_actions))
        with patch.object(appmod.QMessageBox,"warning"):
            self.window.on_finished("submit",(request_id,"GitHub 403"),None)
        self.assertEqual(self.window.list_count.text(),"1 elementos")
        self.assertEqual(self.window.pending_actions,{})
        self.assertEqual(self.window.optimistic_hides,{})

    def test_success_receipt_keeps_card_hidden_until_remote_state_catches_up(self):
        item=self._ready("ttendencias","trend-success")
        self.window.trends=[item]
        self.window.change_section("Tendencias · Listas")
        self.window.select_item(item,load_image=False)
        with patch.object(self.window.worker,"run"):
            self.window.editorial_action("published",confirmed=True)
        request_id=next(iter(self.window.pending_actions))
        self.window.docs["action_receipts"]={"items":[{"request_id":request_id,
            "project":"ttendencias","event_id":"trend-success","status":"applied"}]}
        self.window.confirm_pending()
        self.window.render_list()
        self.assertEqual(self.window.list_count.text(),"0 elementos")
        self.assertEqual(self.window.pending_actions,{})
        self.assertEqual(len(self.window.optimistic_hides),1)
        self.window.trends=[]
        self.window.reconcile_optimistic_closures()
        self.assertEqual(self.window.optimistic_hides,{})

    def test_receipt_failure_restores_card(self):
        item=self._ready("ttendencias","trend-rejected")
        self.window.trends=[item]
        self.window.change_section("Tendencias · Listas")
        self.window.select_item(item,load_image=False)
        with patch.object(self.window.worker,"run"):
            self.window.editorial_action("deleted",confirmed=True)
        request_id=next(iter(self.window.pending_actions))
        self.window.docs["action_receipts"]={"items":[{"request_id":request_id,"status":"rejected"}]}
        self.window.confirm_pending()
        self.window.render_list()
        self.assertEqual(self.window.list_count.text(),"1 elementos")
        self.assertEqual(self.window.pending_actions,{})

    def test_multiple_cards_can_close_independently(self):
        first=self._ready("ttittulares","news-1")
        second=self._ready("ttittulares","news-2")
        self.window.news=[first,second]
        self.window.change_section("Noticias · Listas")
        with patch.object(self.window.worker,"run") as worker:
            self.window.select_item(first,load_image=False)
            self.window.editorial_action("published",confirmed=True)
            self.window.select_item(second,load_image=False)
            self.window.editorial_action("deleted",confirmed=True)
            self.assertEqual(worker.call_count,2)
        self.assertEqual(self.window.list_count.text(),"0 elementos")
        self.assertEqual(len(self.window.pending_actions),2)
        self.assertEqual(self.window.metric_subtitles["published_news"].text(),"+1 pendiente")

    def test_unknown_receipt_timeout_does_not_hide_forever(self):
        item=self._ready("ttittulares","news-timeout")
        self.window.news=[item]
        self.window.change_section("Noticias · Listas")
        self.window.select_item(item,load_image=False)
        with patch.object(self.window.worker,"run"):
            self.window.editorial_action("published",confirmed=True)
        request=next(iter(self.window.pending_actions.values()))
        request["since"]-=81
        self.window.confirm_pending()
        self.window.render_list()
        self.assertEqual(self.window.list_count.text(),"0 elementos",
            "An accepted GitHub operation must not resurrect after 80 seconds")
        self.assertNotEqual(self.window.pending_actions,{})
        request["since"]-=525
        self.window.confirm_pending()
        self.window.render_list()
        self.assertEqual(self.window.list_count.text(),"1 elementos")
        self.assertEqual(self.window.pending_actions,{})

    def test_fetch_pins_all_sources_to_one_immutable_commit(self):
        sha="a"*40
        paths=[]
        def fake_request(url,**kwargs):
            if "/commits/main" in url:
                return 200,{"sha":sha}
            paths.append(url)
            return 200,{"items":[]}
        with (patch.object(appmod,"request",side_effect=fake_request),
              patch.object(appmod,"load_archive_paths",return_value={}),
              patch.object(appmod,"session_token",return_value="github_pat_test")):
            docs,processed=appmod.fetch_editorial()
        self.assertEqual(len(paths),len(appmod.FILES))
        self.assertTrue(all("/"+sha+"/" in url for url in paths))
        self.assertNotIn("/main/", "".join(paths))
        self.assertEqual(docs["_commit_sha"],sha)

    def test_confirmed_mobile_action_cannot_resurrect_in_windows(self):
        closed=self._ready("ttittulares","closed-from-iphone")
        self.window.news=[closed]
        self.window.change_section("Noticias · Listas")
        self.window.docs={"action_receipts":{"items":[{"project":"ttittulares",
            "event_id":"closed-from-iphone","revision":0,"decision":"deleted",
            "status":"applied","at":"2026-10-29T09:25:00Z"}]}}
        marks=appmod.confirmed_terminals(self.window.docs)
        self.window.verified_terminals.update(marks)
        self.window.render_list()
        self.assertEqual(self.window.list_count.text(),"0 elementos")
        newer={**closed,"revision":1}
        self.window.news=[newer]
        self.window.render_list()
        self.assertEqual(self.window.list_count.text(),"1 elementos",
            "A genuinely new revision must not be hidden by the old decision")

    def test_top30_is_not_hidden_by_old_listas_closure(self):
        row={**self._ready("ttendencias","trend-top"),"state":"Top 30"}
        self.window.top30=[row]
        self.window.verified_terminals[("ttendencias","trend-top")]={
            "revision":0,"at":appmod.dt.datetime.now(appmod.dt.timezone.utc)}
        self.window.change_section("Tendencias · Top 30")
        self.assertEqual(len(self.window.visible_rows(self.window.list_data())),1)

    def test_parity_tools_are_available_without_phone(self):
        row={"project":"ttendencias","id":"t1","revision":0,
             "state":"Listas","title":"Tendencia",
             "body":"Texto confirmado\n🌶️ Remate","category":"Tendencias","source":"","image":""}
        self.window.select_item(row)
        self.assertTrue(self.window.actions["gag"].isEnabled())
        self.assertTrue(self.window.actions["chatgpt"].isEnabled())
        self.assertTrue(self.window.actions["hints"].isEnabled())
        self.window.copy_gag()
        self.assertIn("HECHOS EDITORIALES (SOLO CONTEXTO)",appmod.QApplication.clipboard().text())
        self.assertIn("SOLO IMAGEN, SIN NINGÚN TEXTO",appmod.QApplication.clipboard().text())

    def test_tremending_removed_with_delete_not_publication(self):
        row={"project":"ttittulares","id":"tremending-abc","revision":0,
             "state":"Tremending","title":"Noticia en Tremending",
             "body":"","category":"Noticias","source":"","image":""}
        self.window.select_item(row)
        self.assertTrue(self.window.actions["deleted"].isEnabled())
        self.assertFalse(self.window.actions["published"].isEnabled())


    def test_explicit_publication_outcomes_do_not_confuse_deleted_and_published(self):
        self.assertEqual(appmod.publication_outcome("yes"),"published")
        self.assertEqual(appmod.publication_outcome("no"),"deleted")
        self.assertIsNone(appmod.publication_outcome("cancel"))

    def test_primary_actions_remain_visible_at_compact_window_height(self):
        self.window.resize(1100,700)
        self.window.show()
        appmod.QApplication.processEvents()
        for key in ("copy","gag","chatgpt","x","rework","deleted","published"):
            action=self.window.actions[key]
            self.assertTrue(action.isVisible(),key)
            bottom=action.mapTo(self.window,action.rect().bottomLeft()).y()
            self.assertGreater(bottom,0,key)
            self.assertLessEqual(bottom,self.window.height(),key)
        self.assertEqual(len(self.window.actions),14)

    def test_no_secondary_action_truncation_in_menu(self):
        entries=[action.text() for action in self.window.more_menu.actions()]
        self.assertEqual(len(entries),7)
        self.assertIn("Buscar en X ↗",entries)
        self.assertIn("Añadir pistas a la tendencia",entries)
        self.assertIn("Desestimar",entries)


if __name__=="__main__":
    unittest.main()

