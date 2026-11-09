#!/usr/bin/env python3
"""Names may repeat across independent editorial episodes; zero grouping."""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
TREND = ROOT / "trends"
SCRIPTS = ("auto_queue_new.py", "anticipation.py", "reconcile_prepared_ready.py",
           "requests_json.py", "trend_episode_policy.py", "suppression.py",
           "suppressed-terms.json")
NAMES = ("Metropolitano", "Baena", "#NASCARenDAZN", "Koke", "Jonathan David",
         "Omar", "Rosa Benito", "#CuartoMilenio", "Adeyemi", "Fariñas")


def write(folder, name, data):
    (folder / name).write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def read(folder, name):
    return json.loads((folder / name).read_text(encoding="utf-8"))


class EpisodeResearchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        for s in SCRIPTS:
            shutil.copy2(TREND / s, self.folder / s)
        self.now = datetime.now(ZoneInfo("Europe/Madrid"))
        self.old = (self.now - timedelta(days=5)).isoformat(timespec="seconds")
        self.ranked = [{"rank": i + 1, "name": name, "last_changed_at": self.now.isoformat(timespec="seconds")}
                       for i, name in enumerate(NAMES)]
        write(self.folder, "recent.json", {"selection_method": "consensus",
                                          "sources_used": ["independent-1", "independent-2"],
                                          "captured_at": self.now.isoformat(timespec="seconds"),
                                          "items": self.ranked})
        originals = [{"id": "old-"+str(i), "name": name, "rank": i + 1,
                      "status": "deleted", "revision": 1, "auto_queued": True,
                      "requested_at": self.old, "deleted_at": self.old,
                      "explained_at": self.old, "explanation": "Old verified occurrence"}
                     for i, name in enumerate(NAMES)]
        # An old grouped follower must remain audit-only; it is not a new card.
        originals[1]["group_leader_id"] = "legacy-group-leader"
        originals[1]["grouped_into"] = "legacy-group-leader"
        originals[8]["status"] = "grouped"
        write(self.folder, "requests.json", {"requests": originals})
        write(self.folder, "telegram-manual-explained.json", {
            "items": [{"id": old["id"], "name": old["name"], "status": "explained",
                       "revision": 1, "explained_at": self.old,
                       "explanation": "Old verified occurrence",
                       "group_id": "historical-sports",
                       "group_leader_id": "old-0"}
                      for old in originals]})
        write(self.folder, "prepared.json", {"items": []})
        self.originals = originals

    def run_editor(self):
        p = subprocess.run([sys.executable, str(self.folder / "auto_queue_new.py")],
                           cwd=self.folder, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + "\n" + p.stderr)
        return read(self.folder, "requests.json")["requests"]

    def approve(self):
        write(self.folder, "editor-approved-reviews.json", {
            "batches": [{"id": "ten-20261109", "intent": "research_new_episode",
                         "approved_at": (self.now - timedelta(minutes=10)).isoformat(),
                         "valid_until": (self.now + timedelta(hours=4)).isoformat(),
                         "radar_captured_at": (self.now - timedelta(hours=1)).isoformat(),
                         "names": list(NAMES)}]})

    def test_ten_approved_reviews_are_separate_and_idempotent(self):
        self.approve()
        rows = self.run_editor()
        current = [r for r in rows if r.get("editor_approval_batch_id") == "ten-20261109"]
        self.assertEqual(len(current), 10)
        self.assertEqual({r["name"] for r in current}, set(NAMES))
        self.assertEqual(read(self.folder, "editorial-queue.json")["count"], 10)
        self.assertEqual(len({r["id"] for r in current}), 10)
        self.assertTrue(all(r["status"] == "preparing" and
                            not r["new_episode_review"] and
                            not r["distinct_event_required"] and
                            r["recurring_top30_name"] for r in current))
        self.assertTrue(all(r["requested_together"] == [r["name"]] and
                            r["captured_with"] == [r["name"]] and
                            r["grouping_disabled"] is True and
                            r["automatic_grouping"] is False and
                            not r.get("group_id") for r in current))
        for old in self.originals:
            kept = next(r for r in rows if r["id"] == old["id"])
            self.assertEqual(kept["status"], old["status"])
            self.assertEqual(kept.get("group_leader_id"), old.get("group_leader_id"))
        again = self.run_editor()
        self.assertEqual(len(again), len(rows))
        self.assertEqual(read(self.folder, "editorial-queue.json")["count"], 10)

    def test_unapproved_old_names_do_not_republish_on_unchanged_radar(self):
        doc = read(self.folder, "recent.json")
        for row in doc["items"]:
            row.pop("last_changed_at", None)
        write(self.folder, "recent.json", doc)
        rows = self.run_editor()
        self.assertEqual(len(rows), 10)
        self.assertEqual(read(self.folder, "editorial-queue.json")["count"], 0)

    def test_returning_name_with_new_entry_marker_gets_new_id(self):
        doc = read(self.folder, "recent.json")
        doc["items"][1]["entered_top30_at"] = (
            self.now - timedelta(hours=1)).isoformat(timespec="seconds")
        # The other nine still have no reentry evidence.
        for row in doc["items"]:
            if row["name"] != "Baena":
                row.pop("last_changed_at", None)
        write(self.folder, "recent.json", doc)
        rows = self.run_editor()
        self.assertEqual(len(rows), 11)
        fresh = [r for r in rows if r["name"] == "Baena" and r["status"] == "preparing"]
        self.assertEqual(len(fresh), 1)
        self.assertNotEqual(fresh[0]["id"], "old-1")
        self.assertEqual(fresh[0]["radar_episode_token"][:8], "reentry:")
        self.assertEqual(len(self.run_editor()), 11)

    def test_no_new_grouped_status_created_from_two_old_group_members(self):
        rows = self.run_editor()
        self.assertEqual(len(rows), 20)  # All ten have distinct fresh radar movement.
        history = read(self.folder, "telegram-manual-explained.json")["items"]
        self.assertEqual([r["status"] for r in history], ["explained"] * 10)
        self.assertEqual(len([x for x in rows if x["status"] == "preparing"]), 10)

    def test_recent_baena_adeyemi_singletons_are_not_grouped(self):
        # A legacy editor could put a fake grp-<same id> on an individual
        # card. Strip those fields only, not the old closed multi-topic records.
        current = read(self.folder, "requests.json")
        manual = read(self.folder, "telegram-manual-explained.json")
        for name, ident in (("Baena", "baena-new-independent"),
                            ("Adeyemi", "adeyemi-new-independent")):
            now = self.now.isoformat(timespec="seconds")
            row = {"id": ident, "name": name, "revision": 0, "status": "explained",
                   "requested_at": now, "explained_at": now,
                   "explanation": "Hechos actuales individuales",
                   "group_id": "grp-" + ident,
                   "explanation_group_id": "grp-" + ident,
                   "group_leader_id": ident,
                   "grouped_member_revisions": [{"id": ident, "revision": 0}],
                   "trend_names": [name]}
            current["requests"].append(row)
            manual["items"].append(dict(row))
        write(self.folder, "requests.json", current)
        write(self.folder, "telegram-manual-explained.json", manual)
        rows = self.run_editor()
        manual = read(self.folder, "telegram-manual-explained.json")
        for ident in ("baena-new-independent", "adeyemi-new-independent"):
            for doc in (rows, manual["items"]):
                fixed = next(x for x in doc if x["id"] == ident)
                self.assertEqual(fixed["status"], "explained")
                for key in ("group_id", "explanation_group_id", "group_leader_id",
                            "grouped_member_revisions"):
                    self.assertNotIn(key, fixed, f"{ident} leaked {key}")
        old = next(x for x in rows if x["id"] == "old-1")
        self.assertEqual(old["group_leader_id"], "legacy-group-leader")
        self.assertEqual(old["status"], "deleted")


    def test_buenosdias_review_completed_reopens_current_episode_without_new_event(self):
        # Reproduce 09/11: all past #Buenosdías explanations were deleted;
        # today it has a review_completed/no_distinct_event but no active
        # explained ID. This must become preparing, not Pendientes.
        entry = self.now.isoformat(timespec="seconds")
        doc = read(self.folder, "recent.json")
        doc["items"] = [{"rank": 17, "name": "#Buenosdías",
                          "entered_top30_at": entry,
                          "last_changed_at": entry}]
        write(self.folder, "recent.json", doc)
        historical = {"id": "buenos-old", "name": "#Buenosdías",
                      "status": "deleted", "revision": 0,
                      "requested_at": self.old, "deleted_at": self.old,
                      "explained_at": self.old, "explanation": "Viejo saludo"}
        reviewed = {"id": "buenos-review", "name": "#Buenosdías",
                    "status": "review_completed", "auto_queued": True,
                    "revision": 0, "rank": 17, "review_reason": "no_distinct_event",
                    "radar_episode_started_at": entry,
                    "radar_episode_token": "reentry:" + entry,
                    "requested_at": entry, "review_completed_at": entry}
        write(self.folder, "requests.json", {"requests": [historical, reviewed]})
        write(self.folder, "telegram-manual-explained.json",
              {"items": [historical]})
        after = self.run_editor()
        self.assertEqual([x["id"] for x in after],
                         ["buenos-old", "buenos-review"])
        self.assertEqual(after[-1]["status"], "preparing")
        self.assertFalse(after[-1]["distinct_event_required"])
        self.assertFalse(after[-1]["new_episode_review"])
        self.assertEqual(read(self.folder, "editorial-queue.json")["count"], 1)
        self.assertEqual(read(self.folder, "editorial-queue.json")["items"][0]["id"],
                         "buenos-review")
        self.assertEqual(len(self.run_editor()), 2)
        self.assertEqual(read(self.folder, "editorial-queue.json")["count"], 1)

    def test_felizlunes_current_explanation_stays_explained_without_new_listas(self):
        entry = self.now.isoformat(timespec="seconds")
        doc = read(self.folder, "recent.json")
        doc["items"] = [{"rank": 2, "name": "#FelizLunes",
                          "entered_top30_at": entry,
                          "last_changed_at": entry}]
        write(self.folder, "recent.json", doc)
        previous = {"id": "old-feliz", "name": "#FelizLunes",
                    "revision": 0, "status": "deleted",
                    "deleted_at": self.old, "explained_at": self.old,
                    "explanation": "Lunes anterior"}
        current = {"id": "current-feliz", "name": "#FelizLunes",
                   "revision": 0, "status": "explained",
                   "requested_at": entry, "explained_at": entry,
                   "explanation": "Saludo recurrente actual"}
        write(self.folder, "requests.json", {"requests": [previous, current]})
        write(self.folder, "telegram-manual-explained.json",
              {"items": [previous, current]})
        after = self.run_editor()
        self.assertEqual(len(after), 2)
        self.assertEqual(after[-1]["status"], "explained")
        self.assertEqual(read(self.folder, "editorial-queue.json")["count"], 0)
        self.assertEqual(len(self.run_editor()), 2)

    def test_refuse_unsafe_radar_even_with_approval(self):
        self.approve()
        doc = read(self.folder, "recent.json")
        doc["selection_method"] = "hold-last-good"
        write(self.folder, "recent.json", doc)
        rows = self.run_editor()
        self.assertEqual(len(rows), 10)
        self.assertEqual(read(self.folder, "editorial-queue.json")["count"], 0)


if __name__ == "__main__":
    unittest.main()
