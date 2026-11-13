#!/usr/bin/env python3
"""Pruebas del reloj V2 de 15 minutos: sin red ni escrituras GitHub."""
import base64
import unittest
from datetime import datetime, timezone
from unittest.mock import patch
import top30_tick_v2 as clock

class TickTests(unittest.TestCase):
    def test_quarters(self):
        for m, expect in [(0,"00"),(14,"00"),(15,"15"),(29,"15"),
                          (30,"30"),(44,"30"),(45,"45"),(59,"45")]:
            now = datetime(2026,11,13,17,m,55,tzinfo=timezone.utc)
            self.assertEqual(clock.quarter_slot(now), "2026-11-13T17:"+expect+":00Z")

    def test_timezone_is_utc(self):
        from datetime import timedelta
        tz = timezone(timedelta(hours=1))
        self.assertEqual(clock.quarter_slot(datetime(2026,11,13,18,33,tzinfo=tz)),
                         "2026-11-13T17:30:00Z")

    def test_earlier_slot_needs_tick(self):
        self.assertTrue(clock.should_trigger("TT_V2_REFRESH_SLOT_UTC=2026-11-13T17:00:00Z",
                                             "2026-11-13T17:15:00Z"))

    def test_same_slot_is_idempotent(self):
        self.assertFalse(clock.should_trigger("TT_V2_REFRESH_SLOT_UTC=2026-11-13T17:15:00Z",
                                              "2026-11-13T17:15:00Z"))

    def test_newer_slot_is_not_overwritten(self):
        self.assertFalse(clock.should_trigger("TT_V2_REFRESH_SLOT_UTC=2026-11-13T17:30:00Z",
                                              "2026-11-13T17:15:00Z"))

    def test_dry_run_never_writes(self):
        raw = "Viejo trigger manual"
        with patch.object(clock, "request", return_value={
            "sha":"oldsha", "content":base64.b64encode(raw.encode()).decode()
        }) as mock:
            self.assertEqual(clock.tick("test-token", "2026-11-13T17:15:00Z"),
                             "WOULD_REQUEST")
            self.assertEqual(mock.call_count, 1)
            self.assertEqual(mock.call_args.args[0], "GET")

    def test_same_slot_tick_does_not_write(self):
        raw = "TT_V2_REFRESH_SLOT_UTC=2026-11-13T17:15:00Z\n"
        with patch.object(clock, "request", return_value={
            "sha":"oldsha", "content":base64.b64encode(raw.encode()).decode()
        }) as mock:
            self.assertEqual(clock.tick("test-token", "2026-11-13T17:15:00Z",
                                        execute=True), "ALREADY_REQUESTED")
            self.assertEqual(mock.call_count, 1)

    def test_write_only_isolated_v2_branch(self):
        initial={"sha":"oldsha","content":base64.b64encode(b"old").decode()}
        result={"commit":{"sha":"commit-sha"}}
        updated={"content":base64.b64encode(
            b"TT_V2_REFRESH_SLOT_UTC=2026-11-13T17:15:00Z\n").decode()}
        with patch.object(clock, "request", side_effect=[initial,result,updated]) as mock:
            self.assertEqual(clock.tick("test-token","2026-11-13T17:15:00Z",
                                        execute=True),"SUBMITTED")
            method, auth, payload=mock.call_args_list[1].args
            self.assertEqual(method,"PUT")
            self.assertEqual(payload["branch"],"feature/ttactualidad-v2-clean")
            self.assertEqual(payload["sha"],"oldsha")
            self.assertIn("v2/ttendencias/manual-run-trigger.txt",clock.API)

if __name__ == "__main__":
    unittest.main()
