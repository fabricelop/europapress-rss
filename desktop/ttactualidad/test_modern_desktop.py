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
    @classmethod
    def setUpClass(cls):
        cls.app=QApplication.instance() or QApplication([])
        cls.app.setStyle("Fusion")
        cls.app.setStyleSheet(appmod.STYLE)

    def setUp(self):
        self.window=appmod.MainWindow()
        self.addCleanup(self.window.close)

    def test_layout_has_metric_cards_sidebar_and_actions(self):
        self.assertEqual(len(self.window.nav),9)
        self.assertEqual(len(self.window.metric_labels),4)
        self.assertEqual(len(self.window.actions),8)
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

if __name__=="__main__":
    unittest.main()
