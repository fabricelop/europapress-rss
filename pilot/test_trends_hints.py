"""No production reads/writes: all cases are synthetic dictionaries."""
import copy
import hashlib
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from trends_hints import submit_trend_hints

NOW = "2026-10-27T16:30:00+00:00"
ID = "3ddbfd7e26b4"


def fixture(status="inactive"):
    return [
        {"requests": [{"id": ID, "name": "#FreeParacetamol",
                        "rank": 8, "revision": 0, "status": status,
                        "problem_reason": "No hay fuentes", "auto_queued": True}]},
        {"items": []}, {"items": [], "count": 0}, {"items": []},
        {"items": []}, {"items": []}, {"items": []},
    ]


def run(id, revision, note, data):
    return submit_trend_hints(id, revision, note, NOW, *data)


class EditorHintsTests(unittest.TestCase):
    def test_inactive_freeparacetamol_same_id_new_revision_and_queue(self):
        docs = fixture()
        rev = run(ID, 0, "Buscar etiqueta de la campaña y contrastar https://example.org/pista", docs)
        self.assertEqual(rev, 1)
        req = docs[0]["requests"][0]
        self.assertEqual((req["id"], req["revision"], req["status"]),
                         (ID, 1, "preparing"))
        self.assertFalse(req["auto_queued"])
        self.assertIn("No hay fuentes", str(req["investigation_history"]))
        self.assertEqual(req["user_pistas"][0]["verification"], "unverified_editor_context")
        self.assertIn("Contrasta cada dato", req["rewrite_instruction"])
        self.assertEqual(docs[2]["count"], 1)
        self.assertEqual(docs[2]["items"][0]["id"], ID)

    def test_old_ready_is_invalidated_without_recycling_text(self):
        docs = fixture("explained")
        docs[1]["items"] = [{"id": ID, "name": "#FreeParacetamol",
                              "revision": 0, "rank": 8, "status": "explained",
                              "explanation": "Texto antiguo", "closer_text": "remate viejo"}]
        docs[4]["items"] = [{"event_id": ID, "revision": 0, "status": "sent"}]
        docs[5]["items"] = [{"id": ID, "revision": 0, "explanation": "Texto antiguo"}]
        rev = run(ID, 0, "Esta interpretación anterior es incompleta, contrastar nueva fuente", docs)
        self.assertEqual(rev, 1)
        self.assertFalse(docs[1]["items"])
        self.assertFalse(docs[5]["items"])
        self.assertEqual(docs[4]["items"][0]["status"], "superseded")
        self.assertNotIn("Texto antiguo", str(docs[2]["items"]))

    def test_preserves_editor_notes_through_revisions(self):
        docs = fixture()
        run(ID, 0, "Primera pista de usuario contrastable", docs)
        docs[0]["requests"][0].update(status="problematic", problem_reason="No comprobado")
        docs[2]["items"] = []
        rev = run(ID, 1, "Segunda pista con nuevo contexto verificable", docs)
        self.assertEqual(rev, 2)
        self.assertEqual(len(docs[0]["requests"][0]["user_pistas"]), 2)

    def test_rejects_stale_or_active_without_any_mutation(self):
        for status, revision in [("inactive", 1), ("preparing", 0), ("update", 0)]:
            docs = fixture(status)
            saved = copy.deepcopy(docs)
            with self.assertRaises(ValueError):
                run(ID, revision, "Texto comprobable de ayuda editorial", docs)
            self.assertEqual(docs, saved)

    def test_rejects_terminal_or_short_notes(self):
        docs = fixture("deleted")
        with self.assertRaises(ValueError):
            run(ID, 0, "Este texto no debe reabrir lo cerrado", docs)
        docs = fixture()
        with self.assertRaises(ValueError):
            run(ID, 0, "corto", docs)
        docs[3]["items"] = [{"id": ID, "status": "published"}]
        with self.assertRaises(ValueError):
            run(ID, 0, "Tampoco editar una publicación confirmada", docs)

    def test_first_manual_top30_needs_genuine_radar_identity(self):
        name = "Etiqueta de prueba"
        manual = "manual-" + hashlib.sha256(name.encode()).hexdigest()[:32]
        docs = fixture()
        docs[0] = {"requests": []}
        docs[6] = {"items": [{"name": name, "rank": 23}]}
        self.assertEqual(run(manual, 0, "Pistas sobre posible origen del tema", docs), 0)
        self.assertEqual(docs[0]["requests"][0]["id"], manual)
        self.assertEqual(docs[2]["count"], 1)
        with self.assertRaises(ValueError):
            run("manual-" + "f" * 32, 0, "Identificador inventado no permitido", [
                {"requests": []}, {"items": []}, {"items": []},
                {"items": []}, {"items": []}, {"items": []}, docs[6]])

    def test_rejects_active_queue_race(self):
        docs = fixture()
        docs[2]["items"] = [{"id": ID, "revision": 0, "status": "preparing"}]
        with self.assertRaises(ValueError):
            run(ID, 0, "Pista suficientemente extensa", docs)


if __name__ == "__main__":
    unittest.main()
