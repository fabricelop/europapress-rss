import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("apply_actions", Path(__file__).parent / "apply-ttactualidad-action.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class ActionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.original = mod.ROOT
        mod.ROOT = self.root
        self.addCleanup(lambda: setattr(mod, "ROOT", self.original))
        for file, default in {
            "ttittulares/prepared.json": {"items": [], "count": 0},
            "ttittulares/editorial-queue.json": {"items": [], "count": 0},
            "ttittulares/decisions.json": {"items": []},
            "trends/telegram-image-deliveries.json": {"items": []},
            "trends/telegram-manual-explained.json": {"items": []},
            "trends/requests.json": {"requests": []},
            "trends/editorial-queue.json": {"items": [], "count": 0},
            "trends/mobile-decisions.json": {"items": []},
        }.items():
            self.write(file, default)

    def write(self, name, doc):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(doc), encoding="utf-8")

    def test_tt_ready_delete(self):
        self.write("ttittulares/prepared.json", {"items": [{"event_id": "abc123", "revision": 2}], "count": 1})
        self.write("ttittulares/decisions.json", {"items": []})
        changes, result = mod.apply("ttittulares", "abc123", "deleted", 2)
        self.assertEqual(result, "applied")
        self.assertEqual(changes["ttittulares/prepared.json"]["count"], 0)
        self.assertEqual(changes["ttittulares/decisions.json"]["items"][0]["status"], "deleted")
        self.assertNotIn("telegram/delete-message-queue.json", changes)

    def test_tt_revision_failure_no_changes(self):
        self.write("ttittulares/prepared.json", {"items": [{"event_id": "abc123", "revision": 3}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttittulares", "abc123", "published", 2)
        self.assertEqual(mod.load("ttittulares/decisions.json", {})["items"], [])

    def test_tt_discard_in_progress(self):
        self.write("ttittulares/editorial-queue.json", {
            "items": [{"event_id": "tt123", "revision": 1, "status": "PROCESSING"}], "count": 1})
        changes, result = mod.apply("ttittulares", "tt123", "discard", 1)
        self.assertEqual(result, "applied")
        self.assertEqual(changes["ttittulares/editorial-queue.json"]["items"][0]["status"], "DISMISSED")
        self.assertEqual(changes["ttittulares/editorial-queue.json"]["count"], 0)

    def test_tt_discard_rejects_finished(self):
        self.write("ttittulares/editorial-queue.json", {
            "items": [{"event_id": "tt123", "revision": 1, "status": "READY"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttittulares", "tt123", "discard", 1)

    def test_tr_legacy_delivery_deleted(self):
        self.write("trends/telegram-image-deliveries.json", {"items": [
            {"event_id": "tr123", "revision": 0, "status": "sent"}]})
        changes, result = mod.apply("ttendencias", "tr123", "deleted", 0)
        self.assertEqual(result, "applied")
        self.assertEqual(changes["trends/telegram-image-deliveries.json"]["items"][0]["status"], "deleted")
        self.assertEqual(changes["trends/mobile-decisions.json"]["items"][0]["status"], "deleted")

    def test_tr_discard_now_live(self):
        self.write("trends/requests.json", {"requests": [
            {"id": "tr123", "name": "Tema actual", "revision": 2, "status": "preparing"}]})
        self.write("trends/editorial-queue.json", {
            "items": [{"id": "tr123", "revision": 2, "status": "preparing"}], "count": 1})
        cmd = {"project":"ttendencias","event_id":"tr123","decision":"discard",
               "request_id":"12345678-1111-1111-1111-123456789012","revision":2}
        with patch.dict(os.environ, {"TT_ACTUALIDAD_EVENT_JSON": json.dumps(cmd)}):
            mod.main()
        self.assertEqual(mod.load("trends/mobile-decisions.json", {})["items"][0]["status"], "published")
        self.assertEqual(mod.load("trends/editorial-queue.json", {})["items"][0]["status"], "published")

    def test_tr_discard_cannot_delete_already_ready_same_revision(self):
        self.write("trends/requests.json", {"requests": [
            {"id":"tr123","revision":2,"status":"explained","explanation":"Nuevo contexto"}]})
        self.write("trends/editorial-queue.json", {"items": [
            {"id":"tr123","revision":2,"status":"preparing"}],"count":1})
        self.write("trends/telegram-manual-explained.json", {"items": [
            {"id":"tr123","revision":2,"status":"explained","explanation":"Nuevo contexto"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply_live("ttendencias","tr123","discard",2)
        self.assertEqual(mod.load("trends/requests.json",{})["requests"][0]["status"],"explained")

    def test_tr_stale_revision(self):
        self.write("trends/editorial-queue.json", {
            "items": [{"id": "tr123", "revision": 5, "status": "preparing"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttendencias", "tr123", "discard", 4)

    def test_pilot_synthetic_id_blocked_and_no_write(self):
        data = {"project": "ttittulares", "event_id": "pilot-mobile-abcd1234",
                "decision": "deleted", "request_id": "12345678-1111-1111-1111-123456789012", "revision": 1}
        with patch.dict(os.environ, {"TT_ACTUALIDAD_EVENT_JSON": json.dumps(data)}):
            with self.assertRaises(mod.InvalidAction):
                mod.main()
        self.assertFalse((self.root / "pilot/ttactualidad-action-receipts.json").exists())

    def test_duplicate_request_id_idempotent(self):
        request_id = "12345678-1111-1111-1111-123456789012"
        self.write("pilot/ttactualidad-action-receipts.json", {"version": 1, "items": [
            {"request_id": request_id, "status": "applied"}]})
        data = {"project": "ttittulares", "event_id": "abc123", "decision": "deleted",
                "request_id": request_id, "revision": 1}
        with patch.dict(os.environ, {"TT_ACTUALIDAD_EVENT_JSON": json.dumps(data)}):
            mod.main()
        self.assertEqual(mod.load("ttittulares/prepared.json", {})["items"], [])

    def test_live_rejects_discard_and_published(self):
        for decision in ("discard", "published", "prepare"):
            data = {"project": "ttittulares", "event_id": "abcdef123456",
                    "decision": decision, "request_id": "12345678-1111-1111-1111-123456789012",
                    "revision": 1}
            with patch.dict(os.environ, {"TT_ACTUALIDAD_EVENT_JSON": json.dumps(data)}):
                with self.assertRaises(mod.InvalidAction):
                    mod.main()

    def test_live_rejects_missing_revision(self):
        data = {"project": "ttittulares", "event_id": "abcdef123456",
                "decision": "deleted", "request_id": "12345678-1111-1111-1111-123456789012"}
        with patch.dict(os.environ, {"TT_ACTUALIDAD_EVENT_JSON": json.dumps(data)}):
            with self.assertRaises(mod.InvalidAction):
                mod.main()

    def test_missing_authoritative_doc_fails_closed(self):
        (self.root / "ttittulares/prepared.json").unlink()
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttittulares", "abc123", "deleted", 1)

    def test_tr_ready_deleted(self):
        self.write("trends/telegram-image-deliveries.json", {"items": [
            {"event_id": "tr123", "revision": 4, "status": "sent"},
            {"event_id": "tr123", "revision": 2, "status": "deleted"}]})
        changed, status = mod.apply("ttendencias", "tr123", "deleted", 4)
        self.assertEqual(status, "applied")
        self.assertEqual(changed["trends/telegram-image-deliveries.json"]["items"][0]["status"], "deleted")
        self.assertEqual(changed["trends/mobile-decisions.json"]["items"][0]["status"], "deleted")

    def test_live_tt_ready_delete_and_replay(self):
        self.write("ttittulares/prepared.json", {"items": [{"event_id": "abc123", "revision": 2}], "count": 1})
        data = {"project": "ttittulares", "event_id": "abc123", "decision": "deleted",
                "request_id": "12345678-1111-1111-1111-123456789012", "revision": 2}
        with patch.dict(os.environ, {"TT_ACTUALIDAD_EVENT_JSON": json.dumps(data)}):
            mod.main()
            mod.main()
        self.assertEqual(mod.load("ttittulares/prepared.json", {})["count"], 0)
        self.assertEqual(len(mod.load(mod.LEDGER, {"items":[]})["items"]), 1)

    def test_tr_editorial_ready_deletes_without_telegram_delivery(self):
        self.write("trends/telegram-manual-explained.json", {"items": [
            {"id":"row123","revision":2,"status":"explained","name":"Tendencia prueba",
             "explanation":"Texto completo","explained_at":"2026-10-16T08:00:00Z"}]})
        self.write("trends/requests.json", {"requests": [
            {"id":"row123","revision":2,"status":"explained"}]})
        change, result = mod.apply("ttendencias","row123","deleted",2)
        self.assertEqual(result,"applied")
        self.assertNotIn("trends/telegram-image-deliveries.json",change)
        self.assertEqual(change["trends/telegram-manual-explained.json"]["items"][0]["status"],"deleted")
        self.assertEqual(change["trends/requests.json"]["requests"][0]["status"],"deleted")
        self.assertEqual(change["trends/mobile-decisions.json"]["items"][0]["status"],"deleted")

    def test_tr_editorial_stale_revision_rejected(self):
        self.write("trends/telegram-manual-explained.json", {"items": [
            {"id":"row123","revision":4,"status":"explained","explanation":"Ready"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttendencias","row123","deleted",3)

    def test_tr_editorial_closed_rejected(self):
        self.write("trends/telegram-manual-explained.json", {"items": [
            {"id":"row123","revision":4,"status":"explained","explanation":"Ready",
            "telegram_package_status":"deleted"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttendencias","row123","deleted",4)

    def test_tr_editorial_deleted_also_closes_legacy_delivery(self):
        self.write("trends/telegram-manual-explained.json", {"items": [
            {"id":"row123","revision":4,"status":"explained","explanation":"Ready"}]})
        self.write("trends/telegram-image-deliveries.json", {"items": [
            {"event_id":"row123","revision":4,"status":"sent","final":True}]})
        change, result=mod.apply("ttendencias","row123","deleted",4)
        self.assertEqual(change["trends/telegram-image-deliveries.json"]["items"][0]["status"],"deleted")
        self.assertEqual(change["trends/telegram-manual-explained.json"]["items"][0]["status"],"deleted")


if __name__ == "__main__":
    unittest.main()
