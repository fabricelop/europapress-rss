import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "trends"))
from site_image_delete_contract import (
    DeletionGuardError, PROJECT_ID, reconcile_after_site_deletion,
)


class DeletionContractTests(unittest.TestCase):
    def setUp(self):
        self.entry = {
            "target_id": "listas-joint-abcd1234", "revision": 2,
            "explained_at": "2026-10-31T12:30:00+00:00",
            "explanation": "TT#3 Editorial exacto",
            "sha256": "a" * 64,
            "image_url": "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/listas-joint-abcd1234-r2-aaaaaaaaaaaa.png",
        }
        self.manifest = {"schema_version": 1, "project_id": PROJECT_ID, "images": [copy.deepcopy(self.entry), {**self.entry, "target_id": "another-target"}]}
        self.request = {"project_id": PROJECT_ID, **self.entry}
        self.receipt = {k: self.request[k] for k in ("project_id", "target_id", "revision", "sha256", "image_url")}
        self.receipt.update(status="deleted", storage_missing=True, editorial_link_missing=True)

    def check_rejects(self, changes=None, request_changes=None, manifest_changes=None):
        receipt = {**self.receipt, **(changes or {})}
        request = {**self.request, **(request_changes or {})}
        manifest = copy.deepcopy(self.manifest)
        manifest.update(manifest_changes or {})
        with self.assertRaises(DeletionGuardError):
            reconcile_after_site_deletion(manifest, request, receipt)

    def test_verified_exact_delete_preserves_unrelated_and_input(self):
        old = copy.deepcopy(self.manifest)
        result = reconcile_after_site_deletion(self.manifest, self.request, self.receipt)
        self.assertEqual(len(result["images"]), 1)
        self.assertEqual(result["images"][0]["target_id"], "another-target")
        self.assertEqual(self.manifest, old)

    def test_rejects_unverified_or_partial_site_deletion(self):
        for changes in ({"status": "pending"}, {"storage_missing": False}, {"editorial_link_missing": False}, {"status": "deleted", "storage_missing": "true"}):
            with self.subTest(changes=changes):
                self.check_rejects(changes=changes)

    def test_rejects_wrong_site_receipt_identity(self):
        for key, value in (("sha256", "b" * 64), ("revision", 1), ("target_id", "other-id"), ("image_url", "https://example.com/a.png"), ("project_id", "another-project")):
            with self.subTest(key=key):
                self.check_rejects(changes={key: value})

    def test_rejects_stale_catalog(self):
        self.check_rejects(request_changes={"explanation": "changed"})
        self.check_rejects(request_changes={"sha256": "b" * 64})
        self.check_rejects(request_changes={"explained_at": "2026-11-01"})

    def test_rejects_duplicate_or_absent_id_revision(self):
        self.check_rejects(manifest_changes={"images": [self.entry, self.entry]})
        self.check_rejects(manifest_changes={"images": []})

    def test_rejects_malicious_url_and_invalid_revision(self):
        for url in ("https://evil.example/images/ttendencias/x.png", "http://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/x.png", "https://ttactualidad-tendencias.rainyraven22.chatgpt.site.evil.example/images/ttendencias/x.png", "https://ttactualidad-tendencias.rainyraven22.chatgpt.site/images/ttendencias/x.png?force=1"):
            self.check_rejects(request_changes={"image_url": url})
        self.check_rejects(request_changes={"revision": True})
        self.check_rejects(request_changes={"revision": -1})

    def test_wrong_project_or_schema(self):
        self.check_rejects(manifest_changes={"project_id": "someone-else"})
        self.check_rejects(manifest_changes={"schema_version": 2})


if __name__ == "__main__":
    unittest.main()
