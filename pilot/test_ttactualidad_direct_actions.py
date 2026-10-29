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
            "telegram/editorial-processing.json": {"items": []},
            "ttittulares/editorial-queue.json": {"items": [], "count": 0},
            "ttittulares/decisions.json": {"items": []},
            "ttittulares/status.json": {"processing_items": [], "problematic_items": [], "three_source_items": []},
            "trends/telegram-image-deliveries.json": {"items": []},
            "trends/telegram-manual-explained.json": {"items": []},
            "trends/prepared.json": {"items": []},
            "trends/prepared.json": {"items": []},
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
        self.assertEqual(changes["ttittulares/decisions.json"]["items"][0]["revision"], 2)
        self.assertNotIn("telegram/delete-message-queue.json", changes)

    def test_tt_published_revision_saved_for_iphone_0421(self):
        """Without revision, 0.4.21 cannot clear stale 'Sin confirmar' alerts."""
        self.write("ttittulares/prepared.json", {
            "items": [{"event_id": "7024c36e404e", "revision": 1}], "count": 1})
        changes, status = mod.apply("ttittulares", "7024c36e404e", "published", 1)
        self.assertEqual(status, "applied")
        final = changes["ttittulares/decisions.json"]["items"][0]
        self.assertEqual((final["event_id"], final["revision"], final["status"]),
                         ("7024c36e404e", 1, "published"))
        self.assertEqual(changes["ttittulares/prepared.json"]["items"], [])

    def test_tt_completed_publication_rejects_conflicting_delete(self):
        """Do not change an already-published item into an unverified deletion."""
        self.write("ttittulares/decisions.json", {
            "items": [{"event_id": "7ca2e207fd62",
                       "revision": 1, "status": "published"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttittulares", "7ca2e207fd62", "deleted", 1)
        self.assertEqual(mod.load("ttittulares/decisions.json", {})["items"][0]["status"],
                         "published")

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

    def test_live_discard_prevents_late_ready_without_publication(self):
        self.write("ttittulares/editorial-queue.json", {
            "items": [{"event_id": "abc123", "revision": 1, "status": "PROCESSING"}],
            "count": 1})
        self.write("telegram/editorial-processing.json", {
            "items": [{"event_id": "abc123", "revision": 1, "status": "PROCESSING"}]})
        changes, result = mod.apply_live("ttittulares", "abc123", "discard", 1)
        self.assertEqual(result, "applied")
        self.assertEqual(changes["ttittulares/editorial-queue.json"]["items"][0]["status"], "DISMISSED")
        self.assertEqual(changes["telegram/editorial-processing.json"]["items"][0]["status"], "DISMISSED")
        self.assertEqual(changes["ttittulares/decisions.json"]["items"][0]["status"], "dismissed")
        self.assertNotIn("ttittulares/prepared.json", changes)
        self.assertEqual(mod.load("ttittulares/prepared.json", {})["items"], [])

    def test_live_discard_keeps_other_processing_news(self):
        self.write("ttittulares/editorial-queue.json", {"items": [
            {"event_id": "abc123", "revision": 1, "status": "PROCESSING"},
            {"event_id": "xyz987", "revision": 1, "status": "PROCESSING"}], "count": 2})
        self.write("telegram/editorial-processing.json", {"items": [
            {"event_id": "abc123", "revision": 1, "status": "PROCESSING"},
            {"event_id": "xyz987", "revision": 1, "status": "PROCESSING"}]})
        changes, _ = mod.apply_live("ttittulares", "abc123", "discard", 1)
        self.assertEqual(changes["ttittulares/editorial-queue.json"]["count"], 1)
        self.assertEqual(changes["telegram/editorial-processing.json"]["items"][1]["status"], "PROCESSING")

    def test_live_discard_races_same_revision_ready(self):
        self.write("ttittulares/prepared.json", {
            "items": [{"event_id": "abc123", "revision": 1},
                      {"event_id": "other456", "revision": 1}], "count": 2})
        self.write("telegram/editorial-processing.json", {
            "items": [{"event_id": "abc123", "revision": 1, "status": "READY"},
                      {"event_id": "other456", "revision": 1, "status": "PROCESSING"}]})
        changes, result = mod.apply_live("ttittulares", "abc123", "discard", 1)
        self.assertEqual(result, "applied")
        self.assertEqual(changes["ttittulares/prepared.json"]["count"], 1)
        self.assertEqual(changes["ttittulares/prepared.json"]["items"][0]["event_id"], "other456")
        mirror = changes["telegram/editorial-processing.json"]["items"]
        self.assertEqual(mirror[0]["status"], "DISMISSED")
        self.assertEqual(mirror[1]["status"], "PROCESSING")
        terminal = changes["ttittulares/decisions.json"]["items"][0]
        self.assertEqual((terminal["event_id"], terminal["revision"], terminal["status"]),
                         ("abc123", 1, "dismissed"))

    def test_live_discard_ready_stale_revision_rejected(self):
        self.write("ttittulares/prepared.json", {
            "items": [{"event_id": "abc123", "revision": 2}], "count": 1})
        with self.assertRaises(mod.InvalidAction):
            mod.apply_live("ttittulares", "abc123", "discard", 1)
        self.assertEqual(mod.load("ttittulares/prepared.json", {})["count"], 1)

    def test_live_discard_does_not_override_publication(self):
        self.write("ttittulares/prepared.json", {
            "items": [{"event_id": "abc123", "revision": 1}], "count": 1})
        self.write("ttittulares/decisions.json", {
            "items": [{"event_id": "abc123", "revision": 1, "status": "published"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply_live("ttittulares", "abc123", "discard", 1)

    def test_live_discard_fails_closed_on_stale_revision(self):
        self.write("ttittulares/editorial-queue.json", {
            "items": [{"event_id": "abc123", "revision": 2, "status": "PROCESSING"}], "count": 1})
        with self.assertRaises(mod.InvalidAction):
            mod.apply_live("ttittulares", "abc123", "discard", 1)

    def test_late_outbox_provisional_repair_is_guarded_by_decision(self):
        code = (Path(__file__).resolve().parents[1] /
                "ttittulares/apply_editorial_outbox.py").read_text()
        self.assertIn('processed.append(eid+":blocked-user-terminal")', code)
        self.assertIn('if terminal is not None:', code)
        self.assertLess(code.index('if terminal is not None:'),
                        code.index('provisional_repair=('))

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
                mod.main()
            ack=mod.load(mod.LEDGER, {"items":[]})["items"][-1]
            self.assertEqual(ack["status"],"rejected")
            self.assertEqual(ack["request_id"],data["request_id"])
            self.assertTrue(ack.get("error"))

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


    def test_top30_first_time_rework_creates_clean_active_revision(self):
        import hashlib
        name = "Cucurella"
        self.write("trends/recent.json", {"items": [{"rank": 2, "name": name}]})
        synthetic = "manual-" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:32]
        documents, result = mod.apply_live("ttendencias", synthetic, "rework", 0, name, 2)
        self.assertEqual(result, "applied")
        req = documents["trends/requests.json"]["requests"][0]
        self.assertEqual(req["name"], name)
        self.assertEqual(req["status"], "preparing")
        self.assertEqual(req["originated_from_prior_id"], synthetic)
        self.assertNotIn("explanation", req)
        self.assertEqual(documents["trends/editorial-queue.json"]["count"], 1)
        self.assertEqual(documents["trends/editorial-queue.json"]["items"][0]["id"], req["id"])

    def test_historical_published_trend_rework_when_outside_top30(self):
        self.write("trends/recent.json", {"items":[]})
        self.write("trends/telegram-manual-explained.json", {"items":[{
            "id":"be8d15b587e1","revision":0,"name":"Fatima Banez",
            "status":"published"}]})
        changes,status=mod.apply_live("ttendencias","be8d15b587e1",
            "rework",0,"Fatima Banez",4)
        self.assertEqual(status,"applied")
        queued=changes["trends/editorial-queue.json"]["items"]
        self.assertEqual(len(queued),1)
        self.assertEqual(queued[0]["originated_from_prior_id"],"be8d15b587e1")
        self.assertNotEqual(queued[0]["id"],"be8d15b587e1")
        self.assertEqual(changes["trends/telegram-manual-explained.json"]["items"][0]["status"],"published")

    def test_historical_forgery_still_rejected(self):
        self.write("trends/recent.json", {"items":[]})
        self.write("trends/telegram-manual-explained.json", {"items":[{
            "id":"be8d15b587e1","revision":0,"name":"Fatima Banez",
            "status":"published"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply_live("ttendencias","invented-123","rework",0,"Fatima Banez",4)

    def test_top30_first_time_rework_rejects_spoofed_identity(self):
        self.write("trends/recent.json", {"items": [{"rank": 5, "name": "Bellingham"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply_live("ttendencias", "manual-spoofed", "rework", 0, "Bellingham", 5)


    def test_tr_prepared_ready_without_manual_ledger_can_be_removed(self):
        self.write("trends/requests.json", {"requests": [
            {"id": "orphan-ready", "revision": 0, "status": "ready",
             "ready_at": "2026-10-28T03:00:30Z", "delivery_confirmation": "prepared_web"}]})
        self.write("trends/prepared.json", {"items": [
            {"id": "orphan-ready", "revision": 0, "group_leader_id": "orphan-ready",
             "explanation": "TT#7 Tendencia explicada."}]})
        change, result = mod.apply("ttendencias", "orphan-ready", "deleted", 0)
        self.assertEqual(result, "applied")
        self.assertEqual(change["trends/requests.json"]["requests"][0]["status"], "deleted")
        self.assertEqual(change["trends/mobile-decisions.json"]["items"][0]["status"], "deleted")
        self.assertNotIn("trends/telegram-manual-explained.json", change)

    def test_tr_ready_missing_prepared_can_be_deleted_only_with_proof(self):
        self.write("trends/requests.json", {"requests": [
            {"id": "orphan-ready", "revision": 0, "status": "ready",
             "ready_at": "2026-10-28T03:00:30Z", "delivery_confirmation": "prepared_web"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttendencias", "orphan-ready", "published", 0)
        changed, status = mod.apply("ttendencias", "orphan-ready", "deleted", 0)
        self.assertEqual(status, "applied")
        self.assertEqual(changed["trends/requests.json"]["requests"][0]["status"], "deleted")

    def test_tr_unproven_ready_cannot_be_deleted(self):
        self.write("trends/requests.json", {"requests": [
            {"id": "unverified", "revision": 0, "status": "ready"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttendencias", "unverified", "deleted", 0)

    def test_tr_prepared_ready_does_not_override_active_work(self):
        self.write("trends/requests.json", {"requests": [
            {"id": "orphan-ready", "revision": 0, "status": "ready",
             "ready_at": "2026-10-28T03:00:30Z", "delivery_confirmation": "prepared_web"}]})
        self.write("trends/prepared.json", {"items": [
            {"id": "orphan-ready", "revision": 0, "explanation": "TT#7 Lista"}]})
        self.write("trends/editorial-queue.json", {"items": [
            {"id": "orphan-ready", "revision": 0, "status": "preparing"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttendencias", "orphan-ready", "deleted", 0)

    def test_tr_prepared_ready_rejects_new_revision(self):
        self.write("trends/requests.json", {"requests": [
            {"id": "orphan-ready", "revision": 1, "status": "ready",
             "ready_at": "2026-10-28T03:00:30Z", "delivery_confirmation": "prepared_web"}]})
        self.write("trends/prepared.json", {"items": [
            {"id": "orphan-ready", "revision": 0, "explanation": "TT#7 Lista"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttendencias", "orphan-ready", "deleted", 0)

    def test_tr_prepared_ready_cannot_override_published(self):
        self.write("trends/requests.json", {"requests": [
            {"id": "orphan-ready", "revision": 0, "status": "published"}]})
        self.write("trends/prepared.json", {"items": [
            {"id": "orphan-ready", "revision": 0, "explanation": "TT#7 Lista"}]})
        with self.assertRaises(mod.InvalidAction):
            mod.apply("ttendencias", "orphan-ready", "deleted", 0)



if __name__ == "__main__":
    unittest.main()
