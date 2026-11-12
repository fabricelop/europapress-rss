import unittest
from datetime import datetime, timedelta, timezone
from v2.ttendencias.assess_freshness import evaluate


NOW = datetime(2026, 11, 12, 23, 0, tzinfo=timezone.utc)


def row(age=2, *, terms=None, country="ES", mode="live"):
    return {
        "country": country, "mode": mode, "count": 30,
        "top30": terms or [f"Termino {i}" for i in range(1, 31)],
        "observed_at": (NOW - timedelta(minutes=age)).isoformat(),
    }


class FreshnessTests(unittest.TestCase):
    def test_recent_capture_still_unverified(self):
        x = evaluate(row(), now=NOW)
        self.assertEqual(x["status"], "capture_recent_source_unverified")
        self.assertFalse(x["eligible_for_editorial"])
        self.assertIsNone(x["source_observed_at"])

    def test_expired_capture(self):
        x = evaluate(row(31), now=NOW)
        self.assertEqual(x["status"], "capture_expired")

    def test_unchanged_does_not_mean_stale(self):
        x = evaluate(row(2), now=NOW, previous=row(12))
        self.assertFalse(x["comparison"]["ranking_changed"])
        self.assertFalse(x["source_freshness_verified"])

    def test_changed_does_not_mean_verified(self):
        names = [f"Termino {i}" for i in range(1, 31)]
        names[0] = "Nueva tendencia"
        x = evaluate(row(2, terms=names), now=NOW, previous=row(12))
        self.assertTrue(x["comparison"]["ranking_changed"])
        self.assertFalse(x["eligible_for_editorial"])

    def test_reject_test_fixture(self):
        with self.assertRaises(ValueError):
            evaluate(row(mode="fixture"), now=NOW)

    def test_reject_future_clock(self):
        with self.assertRaises(ValueError):
            evaluate(row(-10), now=NOW)

    def test_reject_reversed_comparison(self):
        with self.assertRaises(ValueError):
            evaluate(row(10), now=NOW, previous=row(2))


if __name__ == "__main__":
    unittest.main()
