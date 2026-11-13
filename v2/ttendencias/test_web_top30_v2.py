#!/usr/bin/env python3
"""Contrato público del Top30 V2, sin red ni efectos."""
import unittest
from v2.ttendencias.web_top30_v2 import build


def fixtures():
    names = ["Trend%02d" % n for n in range(1, 31)]
    topics = {}
    items = {}
    for i, name in enumerate(names, 1):
        ident = "trv2-id-%02d" % i
        topics[name] = {"name": name, "trend_id": ident, "active": True,
                        "rank": i, "last_change": "unchanged"}
        items[ident] = {"name": name, "trend_id": ident, "status": "pending",
                        "revision": 1, "secret": "DO_NOT_LEAK"}
    h = {"step": "03_movement", "country": "ES",
         "observed_at": "2026-11-13T17:45:00+00:00",
         "source": "GetDayTrends", "top30": names, "topics": topics}
    q = {"step": "04_editorial_queue", "effects_enabled": False,
         "source_observed_at": h["observed_at"], "items": items}
    return h, q


class Top30WebTests(unittest.TestCase):
    def test_exact_order_and_count(self):
        h, q = fixtures()
        doc = build(h, q)
        self.assertEqual(doc["count"], 30)
        self.assertEqual([t["rank"] for t in doc["items"]], list(range(1,31)))
        self.assertEqual(doc["items"][0]["name"], "Trend01")
        self.assertFalse(doc["publication_allowed"])

    def test_no_auth_or_lease_leak(self):
        h, q = fixtures()
        q["items"]["trv2-id-01"]["lease"]={"token": "secret-lease"}
        q["items"]["trv2-id-01"]["send_intent"]={"token": "secret-send"}
        doc = build(h, q)
        self.assertNotIn("secret", str(doc))
        self.assertNotIn("token", str(doc))

    def test_in_progress_shows_elaboration(self):
        h, q = fixtures()
        q["items"]["trv2-id-01"]["status"]="in_progress"
        doc = build(h, q)
        self.assertEqual(doc["items"][0]["status"], "en_elaboracion")

    def test_expired_lease_is_incident_without_reopening_chat(self):
        h,q=fixtures()
        q["items"]["trv2-id-01"]["status"]="in_progress"
        q["items"]["trv2-id-01"]["lease"]={"token":"NEVER_EXPOSE",
            "expires_at":"2026-01-01T00:00:00Z"}
        row=build(h,q)["items"][0]
        self.assertEqual(row["status"],"incidencia")
        self.assertEqual(row["status_label"],"Elaboración interrumpida")
        self.assertNotIn("NEVER_EXPOSE",str(row))

    def test_capture_verified_shows_text_and_cause(self):
        h, q = fixtures()
        row=q["items"]["trv2-id-01"]
        row["status"]="captured_review"
        row["capture"]={"revision":1, "verified_complete":True,
                        "answer":"Un texto editorial documentado " * 5
                                 +"\nESTADO_CAUSA: NO_CONFIRMADA",
                        "sha256":"f"*64,"chat_url":"https://chatgpt.com/c/valid-chat",
                        "captured_at":"2026-11-13T17:50:00+00:00"}
        doc=build(h, q); first=doc["items"][0]
        self.assertEqual(first["status"], "explicada")
        self.assertEqual(first["cause_status"], "no_confirmada")
        self.assertTrue(first["pending_editorial_review"])
        self.assertTrue(first["chat_url"].startswith("https://chatgpt.com/c/"))

    def test_incomplete_capture_is_incident_not_explained(self):
        h, q = fixtures()
        q["items"]["trv2-id-01"].update(status="captured_review",
                                          capture={"revision":1,"answer":"too short",
                                                   "verified_complete":False})
        doc=build(h,q)
        self.assertEqual(doc["items"][0]["status"],"incidencia")
        self.assertEqual(doc["items"][0]["explanation"],"")

    def test_capture_recovery_shows_incident(self):
        h, q=fixtures()
        q["items"]["trv2-id-01"]["status"]="capture_recovery"
        self.assertEqual(build(h,q)["items"][0]["status"],"incidencia")

    def test_mismatch_refused(self):
        h, q=fixtures()
        q["source_observed_at"]="2026-11-13T17:44:00+00:00"
        with self.assertRaises(ValueError):
            build(h,q)

    def test_incomplete_top30_refused(self):
        h,q=fixtures()
        h["top30"].pop()
        with self.assertRaises(ValueError):
            build(h,q)

    def test_duplicate_ranks_refused(self):
        h,q=fixtures()
        h["topics"]["Trend02"]["rank"]=1
        with self.assertRaises(ValueError):
            build(h,q)

    def test_no_effects_enabled(self):
        h,q=fixtures()
        q["effects_enabled"]=True
        with self.assertRaises(ValueError):
            build(h,q)


if __name__ == "__main__":
    unittest.main()
