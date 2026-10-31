"""Regression checks for exact TTActualidad iPhone Top30 explanation selection."""
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "trends"))
from export_site_top30 import export_top30, norm, best_explanations

NOW = datetime(2026, 10, 31, 23, 59, tzinfo=timezone.utc)
HALLOWEEN_OLD = {
    "id": "1510c923e357", "name": "Halloween", "revision": 0,
    "status": "published",
    "explained_at": "2026-10-31T08:55:00+01:00",
    "explanation": "TT#5 Halloween viejo",
}
HALLOWEEN_NEW = {
    "id": "ab65bc5a5cf7", "name": "Halloween", "revision": 0,
    "status": "deleted",  # Quitar de Listas must NOT erase Top30 text
    "updated_at": "2026-10-31T19:29:00+01:00",
    "explained_at": "2026-10-31T19:29:00+01:00",
    "explanation": "TT#1 Halloween actual",
}
GRIMALDO = {
    "id": "0e9ddd785dc2", "name": "Grimaldo", "revision": 0,
    "status": "deleted",
    "explained_at": "2026-10-31T23:10:00+01:00",
    "explanation": "TT#18 Grimaldo actual",
}
RADAR = {
    "captured_at": "2026-10-31T23:50:00+01:00",
    "top30": ["Halloween", "Grimaldo", "En investigación"]
}
IMAGES = {
    "images": [{
        "target_id": HALLOWEEN_NEW["id"], "revision": 0,
        "explanation": HALLOWEEN_NEW["explanation"],
        "explained_at": HALLOWEEN_NEW["explained_at"],
        "image_url": ("https://ttactualidad-tendencias.rainyraven22.chatgpt.site/"
                      "images/ttendencias/ab65bc5a5cf7-r0-aaaaaaaaaaaa.png"),
        "sha256": "a" * 64,
    }]
}


def make(manual=None, requests=None, explained=None, catalog=None, recent=None, now=NOW):
    return export_top30(
        recent or RADAR,
        {"items": manual if manual is not None else [HALLOWEEN_OLD, HALLOWEEN_NEW, GRIMALDO]},
        {"items": explained or []},
        {"requests": requests or []},
        catalog if catalog is not None else IMAGES,
        now=now,
    )


class PublicTop30ParityTests(unittest.TestCase):
    def test_deleted_halloween_newer_than_published(self):
        items = make()["items"]
        self.assertEqual(items[0]["explanation"], "TT#1 Halloween actual")
        self.assertEqual(items[0]["explained_at"], "2026-10-31T19:29:00+01:00")
        self.assertEqual(items[0]["editorial_id"], "ab65bc5a5cf7")
        self.assertEqual(items[0]["status"], "EXPLICADA")

    def test_deleted_grimaldo_still_explained_in_top30(self):
        items = make()["items"]
        self.assertEqual(items[1]["explanation"], "TT#18 Grimaldo actual")
        self.assertEqual(items[1]["editorial_id"], "0e9ddd785dc2")
        self.assertEqual(items[1]["status"], "EXPLICADA")
        self.assertEqual(items[2]["status"], "PENDIENTE")

    def test_stale_explanation_not_recycled(self):
        old = {**HALLOWEEN_NEW, "explained_at": "2026-09-01T19:29:00+01:00"}
        out = make(manual=[old])["items"][0]
        self.assertEqual(out["explanation"], "")
        self.assertEqual(out["status"], "PENDIENTE")

    def test_requests_can_supply_newer_explanation_and_editorial_status(self):
        newer = {**GRIMALDO, "explanation": "Nueva explicación de request",
                 "updated_at": "2026-10-31T23:30:00+01:00"}
        out = make(requests=[newer])["items"][1]
        self.assertEqual(out["explanation"], "Nueva explicación de request")
        processing = {**newer, "explanation": "", "status": "preparing"}
        out = make(requests=[processing])["items"][1]
        self.assertEqual(out["explanation"], GRIMALDO["explanation"])
        self.assertEqual(out["status"], "EN ELABORACIÓN")

    def test_joint_does_not_overwrite_member_individual(self):
        joint = {
            "id": "listas-joint-1", "name": "Grupo deportivo", "revision": 0,
            "listas_group_role": "joint", "trend_names": ["Grimaldo"],
            "explained_at": "2026-10-31T23:50:00+01:00",
            "explanation": "Grupo, no individual",
        }
        selected = best_explanations({"items": [GRIMALDO, joint]}, {}, {})
        self.assertEqual(selected[norm("Grimaldo")]["id"], GRIMALDO["id"])

    def test_images_do_not_cross_id_revision_or_text(self):
        original = make()["items"][0]["image"]
        self.assertEqual(original["status"], "catalog_recorded")
        self.assertEqual(original["sha256"], "a" * 64)
        stale = {**IMAGES["images"][0], "explanation": "old text"}
        self.assertIsNone(make(catalog={"images": [stale]})["items"][0]["image"])
        wrong_id = {**IMAGES["images"][0], "target_id": HALLOWEEN_OLD["id"]}
        self.assertIsNone(make(catalog={"images": [wrong_id]})["items"][0]["image"])

    def test_timezone_and_search_numeration(self):
        self.assertEqual(norm("  Óscar   Puente "), "oscar puente")
        items = make()["items"]
        self.assertEqual([x["card_id"] for x in items], ["rank-1", "rank-2", "rank-3"])
        self.assertEqual([x["rank"] for x in items], [1, 2, 3])


if __name__ == "__main__":
    unittest.main()
