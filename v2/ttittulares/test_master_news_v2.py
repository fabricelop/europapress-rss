"""Regression tests for the radar-only master feed."""
import copy
import unittest
from datetime import datetime, timedelta, timezone

from .master_news_v2 import project_master_news
from .source_catalog_v2 import load_catalog


class MasterNewsTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 11, 19, 17, tzinfo=timezone.utc)
        self.stamp = self.now.isoformat().replace("+00:00", "Z")
        config = load_catalog()
        families = {}
        for source in config["sources"]:
            if source["type"] == "general":
                families.setdefault(source["family"], source["name"])
        self.assertGreaterEqual(len(families), 4)
        self.families = list(families.items())[:4]

    def event(self, event_id="ttn2-" + "a" * 24):
        title = "El tribunal anuncia una nueva sentencia sobre la norma de transporte"
        return {"event_id": event_id, "canonical_title": title,
                "canonical_url": "https://example.com/a", "status": "eligible",
                "first_seen_at": self.stamp, "eligible_at": self.stamp,
                "last_seen_at": self.stamp, "source_count": 4,
                "appearances": [{"source": source, "source_family": family,
                                 "source_type": "general", "title": title,
                                 "url": f"https://{index}.example.org/story",
                                 "published_at": self.stamp}
                                for index, (family, source) in enumerate(self.families)]}

    def scan(self, events):
        return {"observed_at": self.stamp,
                "items": {event["event_id"]: event for event in events}}

    def test_only_four_independent_confirming_sources_pass(self):
        event = self.event()
        self.assertEqual(project_master_news(self.scan([event]), now=self.now)["count"], 1)
        unverified = copy.deepcopy(event)
        unverified["appearances"] = unverified["appearances"][:3]
        self.assertEqual(project_master_news(self.scan([unverified]), now=self.now)["count"], 0)

    def test_no_editorial_fields_or_images(self):
        result = project_master_news(self.scan([self.event()]), now=self.now)["items"][0]
        self.assertNotIn("revision", result)
        self.assertNotIn("image", result)
        self.assertNotIn("editorial_job_id", result)

    def test_duplicate_same_fact_keeps_first_id(self):
        original = self.event()
        duplicate = self.event("ttn2-" + "b" * 24)
        duplicate["eligible_at"] = (self.now + timedelta(minutes=3)).isoformat().replace("+00:00", "Z")
        self.assertEqual(project_master_news(self.scan([original, duplicate]),
                                             now=self.now + timedelta(minutes=5))["items"][0]["id"],
                         original["event_id"])

    def test_expired_and_unverified_excluded(self):
        old = self.event()
        old["eligible_at"] = (self.now - timedelta(days=31)).isoformat().replace("+00:00", "Z")
        self.assertEqual(project_master_news(self.scan([old]), now=self.now)["count"], 0)
        fresh = self.event()
        fresh["status"] = "monitoring"
        self.assertEqual(project_master_news(self.scan([fresh]), now=self.now)["count"], 0)


if __name__ == "__main__":
    unittest.main()
