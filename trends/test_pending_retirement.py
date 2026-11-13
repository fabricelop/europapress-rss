"""Quitar de Pendientes closes an occurrence, not a trend name forever."""
import unittest
from datetime import datetime, timedelta, timezone

try:
    from pending_retirement import retire_pending, current_retirement
except ImportError:
    from trends.pending_retirement import retire_pending, current_retirement


NOW = "2026-11-13T21:30:00+01:00"
ENTRY = "2026-11-13T20:30:00+01:00"
NEW_ENTRY = "2026-11-14T09:00:00+01:00"


def fixtures():
    requests = {"requests": [
        {"id": "1ea1a6c850b1", "name": "españas", "revision": 3,
         "status": "problematic", "with_image": True},
        {"id": "other", "name": "Colau", "revision": 1,
         "status": "preparing", "with_image": True},
    ]}
    queue = {"items": [dict(x) for x in requests["requests"]], "count": 2}
    recent = {"items": [{"id": "ignored", "name": "españas", "rank": 9,
                         "entered_top30_at": ENTRY},
                        {"name": "Colau", "rank": 10}]}
    retirements = {"items": []}
    return requests, queue, recent, retirements


class PendingRetirementTests(unittest.TestCase):
    def test_retire_only_exact_pending_revision_and_keep_radar(self):
        requests, queue, recent, retirements = fixtures()
        result = retire_pending(requests, queue, recent, retirements,
                                "1ea1a6c850b1", 3, NOW)
        self.assertEqual(result, "applied")
        self.assertEqual(requests["requests"][0]["status"], "inactive")
        self.assertEqual(requests["requests"][0]["inactive_reason"],
                         "editor_retired_current_occurrence")
        self.assertEqual(requests["requests"][1]["status"], "preparing")
        self.assertEqual([x["name"] for x in queue["items"]], ["Colau"])
        self.assertEqual(queue["count"], 1)
        self.assertEqual([x["name"] for x in recent["items"]], ["españas", "Colau"])
        record = retirements["items"][0]
        self.assertEqual((record["id"], record["revision"]),
                         ("1ea1a6c850b1", 3))
        self.assertIsNotNone(current_retirement("ESPAÑAS", recent["items"][0],
                                                retirements["items"]))
        self.assertIsNone(current_retirement("españas",
            {"name": "españas", "entered_top30_at": NEW_ENTRY},
            retirements["items"]))
        self.assertEqual(retire_pending(requests, queue, recent, retirements,
                                       "1ea1a6c850b1", 3, NOW), "already_applied")
        self.assertEqual(len(retirements["items"]), 1)

    def test_reject_stale_revision_without_erasing_new_work(self):
        requests, queue, recent, retirements = fixtures()
        requests["requests"][0]["revision"] = 4
        with self.assertRaisesRegex(ValueError, "obsoleta"):
            retire_pending(requests, queue, recent, retirements,
                           "1ea1a6c850b1", 3, NOW)
        self.assertEqual(requests["requests"][0]["status"], "problematic")
        self.assertEqual(queue["count"], 2)
        self.assertEqual(retirements["items"], [])

    def test_publication_cannot_be_removed_as_pending(self):
        requests, queue, recent, retirements = fixtures()
        requests["requests"][0]["status"] = "published"
        with self.assertRaisesRegex(ValueError, "No es una tendencia pendiente"):
            retire_pending(requests, queue, recent, retirements,
                           "1ea1a6c850b1", 3, NOW)
        self.assertEqual(retirements["items"], [])

    def test_radar_only_card_and_no_off_radar_fake(self):
        requests = {"requests": []}
        queue = {"items": [], "count": 0}
        recent = {"items": [{"name": "españas", "rank": 12,
                            "entered_top30_at": ENTRY}]}
        retirements = {"items": []}
        self.assertEqual(retire_pending(requests, queue, recent, retirements,
                         "pending-abc", 0, NOW, "españas"), "applied")
        self.assertEqual(retirements["items"][0]["name"], "españas")
        self.assertEqual(requests["requests"], [])
        with self.assertRaisesRegex(ValueError, "no figura"):
            retire_pending(requests, queue, recent, retirements,
                           "pending-xyz", 0, NOW, "Tendencia inventada")

    def test_current_observation_never_requeues_on_refresh_only(self):
        record = [{"name": "españas", "id": "old", "revision": 3,
                   "retired_at": NOW, "entered_top30_at": ENTRY}]
        self.assertIsNotNone(current_retirement("españas",
            {"name": "españas", "entered_top30_at": ENTRY},
            record))
        self.assertIsNotNone(current_retirement("españas",
            {"name": "españas", "last_changed_at": NEW_ENTRY}, record))
        self.assertIsNone(current_retirement("españas",
            {"name": "españas", "entered_top30_at": NEW_ENTRY}, record))
        self.assertIsNone(current_retirement("España",
            {"name": "España", "entered_top30_at": ENTRY}, record))


if __name__ == "__main__":
    unittest.main()
