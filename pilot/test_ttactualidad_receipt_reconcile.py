"""Regression for autonomous, read-only-state receipt reconciliation."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "receipt_reconcile", Path(__file__).parent / "reconcile_ttactualidad_manual_receipts.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

RID = "4edfdbc9-d625-40ae-8d8d-cb43e167209f"
NEWS_ID = "manual-" + RID

class ReconcileManualReceiptTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.original = module.ROOT
        module.ROOT = Path(tmp.name)
        self.addCleanup(lambda: setattr(module, "ROOT", self.original))
        self.save(module.RECEIPTS, {"version":1, "items":[]})
        self.save(module.SOURCES[0], {"items":[]})
        self.save(module.SOURCES[1], {"items":[]})

    def save(self, path, doc):
        p = module.ROOT / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(doc), encoding="utf-8")

    def receipt(self):
        return module.load(module.RECEIPTS)["items"]

    def test_no_queue_no_ack(self):
        self.assertEqual(module.reconcile(), 0)
        self.assertEqual(self.receipt(), [])

    def test_confirmed_manual_queue_recovers_missing_ack_once(self):
        self.save(module.SOURCES[1], {"items":[{
            "event_id":NEWS_ID, "revision":1, "status":"PROCESSING",
            "selection_mode":"TTACTUALIDAD_MANUAL",
            "requested_at":"2026-10-29T15:23:48Z"}]})
        self.assertEqual(module.reconcile(), 1)
        self.assertEqual(module.reconcile(), 0)
        row = self.receipt()[0]
        self.assertEqual(row["request_id"], RID)
        self.assertEqual(row["status"], "applied")
        self.assertEqual(row["decision"], "manual_news")
        self.assertEqual(row["at"], "2026-10-29T15:23:48Z")

    def test_untrusted_manual_like_card_never_acks(self):
        self.save(module.SOURCES[1], {"items":[{
            "event_id":NEWS_ID, "revision":1, "status":"PROCESSING"}]})
        self.assertEqual(module.reconcile(), 0)
        self.assertEqual(self.receipt(), [])

    def test_later_valid_queue_corrects_stale_rejection(self):
        self.save(module.RECEIPTS, {"version":1, "items":[{
            "request_id":RID, "project":"ttittulares",
            "event_id":NEWS_ID, "status":"rejected"}]})
        self.save(module.SOURCES[0], {"items":[{
            "event_id":NEWS_ID, "revision":1,
            "manual_submission":True, "status":"READY"}]})
        self.assertEqual(module.reconcile(), 1)
        self.assertEqual(len(self.receipt()), 1)
        self.assertEqual(self.receipt()[0]["status"], "applied")

    def test_existing_applied_receipts_and_other_decisions_are_untouched(self):
        self.save(module.RECEIPTS, {"version":1, "items":[{
            "request_id":RID, "project":"ttittulares",
            "event_id":NEWS_ID, "status":"applied", "at":"kept"}, {
            "request_id":"unrelated", "decision":"published", "status":"applied"}]})
        self.save(module.SOURCES[1], {"items":[{
            "event_id":NEWS_ID, "revision":1,
            "selection_mode":"TTACTUALIDAD_MANUAL"}]})
        self.assertEqual(module.reconcile(), 0)
        self.assertEqual(self.receipt()[0]["at"], "kept")
        self.assertEqual(len(self.receipt()), 2)

if __name__ == "__main__":
    unittest.main()
