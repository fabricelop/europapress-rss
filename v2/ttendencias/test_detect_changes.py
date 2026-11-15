import unittest
from datetime import datetime, timedelta, timezone

from v2.ttendencias.detect_changes import build, stable_trend_id

BASE = datetime(2026, 11, 12, 22, 0, tzinfo=timezone.utc)
ORIGINAL = [f"Trend {i}" for i in range(1, 31)]


def snap(minutes, names=None):
    return {"mode": "live", "country": "ES", "count": 30,
            "source": "https://getdaytrends.com/es/spain/",
            "observed_at": (BASE + timedelta(minutes=minutes)).isoformat(),
            "top30": list(names or ORIGINAL)}


class ChangeTests(unittest.TestCase):
    def run_step(self, minutes, names=None, prev=None):
        return build(snap(minutes, names), prev, now=BASE + timedelta(minutes=minutes))

    def test_bootstrap_no_thirty_fake_entries(self):
        x = self.run_step(0)
        self.assertEqual(len(x["state"]["topics"]), 30)
        self.assertEqual(x["changes"], [])
        self.assertTrue(x["state"]["bootstrap"])
        self.assertTrue(all(t["trend_id"].startswith("trv2-") for t in x["state"]["topics"].values()))

    def test_unchanged_and_idempotent(self):
        first = self.run_step(0)["state"]
        later = self.run_step(10, prev=first)
        self.assertEqual(later["changes"], [])
        self.assertTrue(later["state"]["ranking_unchanged"])
        self.assertIsNone(later["state"]["ranking_change_at"])
        self.assertIsNone(later["state"]["topics"]["trend 1"]["previous_rank"])
        same = self.run_step(10, prev=later["state"])
        self.assertTrue(same["idempotent"])

    def test_position_delta_compares_adjacent_captures(self):
        first = self.run_step(0)["state"]
        names = ORIGINAL.copy()
        names[0], names[4] = names[4], names[0]
        moved = self.run_step(15, names, first)["state"]
        self.assertEqual(moved["previous_observed_at"], first["observed_at"])
        self.assertEqual(moved["topics"]["trend 5"]["previous_rank"], 5)
        self.assertEqual(moved["topics"]["trend 5"]["positions_changed"], 4)
        self.assertEqual(moved["topics"]["trend 1"]["previous_rank"], 1)
        self.assertEqual(moved["topics"]["trend 1"]["positions_changed"], -4)
        self.assertIsNone(moved["topics"]["trend 2"]["positions_changed"])
        steady = self.run_step(30, names, moved)["state"]
        self.assertTrue(steady["ranking_unchanged"])
        self.assertEqual(steady["ranking_change_at"], moved["observed_at"])
        self.assertEqual(steady["topics"]["trend 5"]["positions_changed"], 4)
        self.assertEqual(steady["topics"]["trend 5"]["previous_rank"], 5)
        self.assertEqual(steady["topics"]["trend 1"]["positions_changed"], -4)
        self.assertIsNone(steady["topics"]["trend 2"]["positions_changed"])
        self.assertEqual(steady["observed_at"], snap(30)["observed_at"])
        still = self.run_step(45, names, steady)["state"]
        self.assertEqual(still["topics"]["trend 5"]["positions_changed"], 4)
        self.assertEqual(still["topics"]["trend 1"]["positions_changed"], -4)
        self.assertEqual(still["ranking_change_at"], moved["observed_at"])

    def test_next_real_change_recalculates_against_last_snapshot(self):
        initial = self.run_step(0)["state"]
        names = ORIGINAL.copy()
        names[0], names[4] = names[4], names[0]
        changed = self.run_step(10, names, initial)["state"]
        identical = self.run_step(20, names, changed)["state"]
        names[0], names[1] = names[1], names[0]
        changed_again = self.run_step(30, names, identical)["state"]
        self.assertFalse(changed_again["ranking_unchanged"])
        self.assertEqual(changed_again["ranking_change_at"], snap(30)["observed_at"])
        self.assertEqual(changed_again["topics"]["trend 2"]["positions_changed"], 1)
        self.assertEqual(changed_again["topics"]["trend 5"]["positions_changed"], -1)
        self.assertEqual(changed_again["topics"]["trend 1"]["positions_changed"], -4)

    def test_per_trend_last_real_movement_survives_others_changing(self):
        initial = self.run_step(0)["state"]
        names = ORIGINAL.copy()
        names[0], names[4] = names[4], names[0]
        first_change = self.run_step(10, names, initial)["state"]
        names[1], names[2] = names[2], names[1]
        another_change = self.run_step(20, names, first_change)
        self.assertEqual(another_change["state"]["topics"]["trend 5"]["positions_changed"], 4)
        self.assertEqual(another_change["state"]["topics"]["trend 5"]["last_change"], "up")
        self.assertEqual(another_change["state"]["topics"]["trend 2"]["positions_changed"], -1)
        self.assertEqual([c["name"] for c in another_change["changes"]], ["Trend 3", "Trend 2"])

    def test_legacy_all_zeros_become_unknown_when_source_is_unchanged(self):
        first = self.run_step(0)["state"]
        legacy = self.run_step(10, prev=first)["state"]
        legacy.pop("ranking_unchanged", None)
        legacy.pop("ranking_change_at", None)
        for item in legacy["topics"].values():
            item.update(last_change="unchanged", previous_rank=item["rank"], positions_changed=0)
        again = self.run_step(20, prev=legacy)["state"]
        self.assertIsNone(again["topics"]["trend 1"]["previous_rank"])
        self.assertIsNone(again["topics"]["trend 1"]["positions_changed"])
        self.assertEqual(again["topics"]["trend 1"]["last_change"], "unverified")

    def test_new_entry_has_no_previous_rank(self):
        first = self.run_step(0)["state"]
        names = ["New"] + ORIGINAL[:29]
        moved = self.run_step(15, names, first)["state"]
        item = moved["topics"]["new"]
        self.assertIsNone(item["previous_rank"])
        self.assertIsNone(item["positions_changed"])
        self.assertEqual(item["last_change"], "entry")

    def test_new_exit_and_ranking(self):
        first = self.run_step(0)["state"]
        names = ["New"] + ORIGINAL[:29]
        x = self.run_step(10, names, first)
        self.assertEqual(len([y for y in x["changes"] if y["kind"] == "entry"]), 1)
        self.assertEqual(len([y for y in x["changes"] if y["kind"] == "exit"]), 1)
        self.assertEqual(len([y for y in x["changes"] if y["kind"] == "down"]), 29)
        self.assertFalse(x["state"]["topics"]["trend 30"]["active"])

    def test_short_return_is_not_new_episode(self):
        base = self.run_step(0)["state"]
        absent = self.run_step(10, ["New"] + ORIGINAL[:29], base)["state"]
        before = base["topics"]["trend 30"]["episode_token"]
        back = self.run_step(20, ORIGINAL, absent)
        self.assertEqual(back["state"]["topics"]["trend 30"]["episode_token"], before)
        self.assertIn("short_return", [e["kind"] for e in back["changes"]])
        self.assertNotEqual(back["state"]["topics"]["trend 30"]["entered_top30_at"], base["topics"]["trend 30"]["entered_top30_at"])

    def test_return_after_35_minutes_keeps_identity_and_explanation(self):
        base = self.run_step(0)["state"]
        absent = self.run_step(10, ["New"] + ORIGINAL[:29], base)["state"]
        back = self.run_step(45, ORIGINAL, absent)
        item = back["state"]["topics"]["trend 30"]
        self.assertEqual(item["trend_id"], base["topics"]["trend 30"]["trend_id"])
        self.assertEqual(item["episode_number"], 1)
        self.assertEqual([x["kind"] for x in back["changes"] if x["name"] == "Trend 30"], ["short_return"])
        self.assertFalse(any(x.get("reexplain_candidate") for x in back["changes"]))

    def test_exactly_24_hours_is_not_reexplanation(self):
        base = self.run_step(0)["state"]
        absent = self.run_step(10, ["New"] + ORIGINAL[:29], base)["state"]
        back = self.run_step(10 + 24*60, ORIGINAL, absent)
        self.assertEqual(back["state"]["topics"]["trend 30"]["episode_number"], 1)
        self.assertFalse(any(x.get("reexplain_candidate") for x in back["changes"]))

    def test_return_over_24h_keeps_same_trend_id(self):
        base = self.run_step(0)["state"]
        absent = self.run_step(10, ["New"] + ORIGINAL[:29], base)["state"]
        back = self.run_step(10 + 24*60 + 1, ORIGINAL, absent)
        item = back["state"]["topics"]["trend 30"]
        token = item["episode_token"]
        self.assertEqual(item["trend_id"], base["topics"]["trend 30"]["trend_id"])
        self.assertEqual(item["episode_number"], 2)
        self.assertNotEqual(token, base["topics"]["trend 30"]["episode_token"])
        self.assertTrue(any(x["kind"] == "reentry" and x["reexplain_candidate"] for x in back["changes"]))
        steady = self.run_step(10 + 24*60 + 11, ORIGINAL, back["state"])
        self.assertEqual(steady["state"]["topics"]["trend 30"]["episode_token"], token)
        self.assertFalse(any(x.get("reexplain_candidate") for x in steady["changes"]))

    def test_months_later_same_id_and_retained_history(self):
        base = self.run_step(0)["state"]
        absent = self.run_step(10, ["New"] + ORIGINAL[:29], base)["state"]
        many_days = self.run_step(60*24*100, ["New"] + ORIGINAL[:29], absent)["state"]
        self.assertIn("trend 30", many_days["topics"])
        back = self.run_step(60*24*100+10, ORIGINAL, many_days)["state"]
        self.assertEqual(back["topics"]["trend 30"]["trend_id"], base["topics"]["trend 30"]["trend_id"])
        self.assertEqual(stable_trend_id("trend 30"), base["topics"]["trend 30"]["trend_id"])

    def test_no_reentry_merely_due_to_age(self):
        base = self.run_step(0)["state"]
        later = self.run_step(60 * 26, ORIGINAL, base)
        self.assertFalse(any(e["kind"] == "reentry" for e in later["changes"]))

    def test_refuse_older_and_inconsistent_snapshots(self):
        base = self.run_step(10)["state"]
        with self.assertRaises(ValueError):
            self.run_step(0, prev=base)
        with self.assertRaises(ValueError):
            self.run_step(10, ["New"] + ORIGINAL[:29], base)

    def test_reject_expired_capture(self):
        with self.assertRaises(ValueError):
            build(snap(0), now=BASE + timedelta(minutes=21))


if __name__ == "__main__":
    unittest.main()
