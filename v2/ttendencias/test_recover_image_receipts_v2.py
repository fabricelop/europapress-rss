#!/usr/bin/env python3
"""Non-destructive recovery of legacy ImageGen originals, without another chat."""
import copy
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch
from PIL import Image

os.environ.setdefault("LOCALAPPDATA", tempfile.gettempdir())
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import image_intake_v2 as intake
import image_job_v2 as jobs
import recover_image_receipts_v2 as recovery

ID = "trv2-a925c974191c00316cbe4398"
CHAT = "https://chatgpt.com/c/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


def fixture(root):
    answer = "Explicación conservada de una tendencia"
    row = {"trend_id": ID, "name": "Tendencia", "revision": 2,
           "status": "captured_review", "capture": {"revision": 2,
           "answer": answer, "sha256": intake.fingerprint(answer)}}
    job = jobs.proposed_job(row, attempt=4, nonce="recoverytest123456")
    row["image_incident"] = {"project": "ttendencias-v2", "trend_id": ID,
                             "revision": 2, "editorial_sha256": job["editorial_sha256"],
                             "command_id": job["command_id"]}
    image = Image.frombytes("RGB", (1024, 576), os.urandom(1024 * 576 * 3))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    raw = buffer.getvalue()
    originals = root / "image-originals"
    journals = root / "image-only-journals"
    originals.mkdir()
    journals.mkdir()
    image_path = originals / (job["command_id"] + ".png")
    image_path.write_bytes(raw)
    (journals / (ID + "-r2-attempt-004.json")).write_text(json.dumps({
        "trend_id": ID, "revision": 2, "attempt": 4,
        "command_id": job["command_id"], "image_chat_url": CHAT,
        "status": "failed"}), encoding="utf-8")
    return {"items": {ID: row}}, job, image_path


class LegacyRecoveryTest(unittest.TestCase):
    def test_recovers_existing_verified_original_without_regeneration_or_upload(self):
        with tempfile.TemporaryDirectory() as folder:
            queue, job, path = fixture(pathlib.Path(folder))
            found = recovery.recoverable(queue, folder)
            self.assertEqual(len(found), 1)
            self.assertEqual(found[0]["job"]["command_id"], job["command_id"])
            expected_sha = recovery.github.git_blob_sha(path.read_bytes())
            with patch.object(recovery.editorial, "queue_read", return_value=(queue, "sha")):
                with patch.object(recovery.github, "current_editorial") as current:
                    with patch.object(recovery.github, "request", return_value={"sha": expected_sha}):
                        with patch.object(recovery.github, "save_original") as upload:
                            def associate(api, auth, tid, rev, digest, receipt):
                                self.assertEqual((tid, rev, digest), (ID, 2, job["editorial_sha256"]))
                                self.assertEqual(receipt["attempt"], 4)
                                queue["items"][ID]["capture"]["image"] = receipt
                            with patch.object(recovery.editorial, "update_image_receipt",
                                              side_effect=associate):
                                self.assertEqual(recovery.recover_one(found[0], None, "auth"), "saved")
                            current.assert_called_once()
                            upload.assert_not_called()
            self.assertTrue(path.is_file())
            self.assertEqual(queue["items"][ID]["capture"]["image"]["status"], "saved")

    def test_no_recovery_for_changed_revision_missing_file_or_other_command(self):
        with tempfile.TemporaryDirectory() as folder:
            queue, job, path = fixture(pathlib.Path(folder))
            row = queue["items"][ID]
            self.assertEqual(len(recovery.recoverable(queue, folder)), 1)
            row["image_incident"]["command_id"] += "-other"
            self.assertEqual(recovery.recoverable(queue, folder), [])
            row["image_incident"]["command_id"] = job["command_id"]
            row["revision"] = 3
            self.assertEqual(recovery.recoverable(queue, folder), [])
            row["revision"] = 2
            path.unlink()
            self.assertEqual(recovery.recoverable(queue, folder), [])

    def test_no_recovery_while_image_running_or_already_saved(self):
        with tempfile.TemporaryDirectory() as folder:
            queue, _, _ = fixture(pathlib.Path(folder))
            row = queue["items"][ID]
            row["image_progress"] = {"status": "in_progress", "expires_at": (
                datetime.now(timezone.utc) + timedelta(minutes=3)).isoformat()}
            self.assertEqual(recovery.recoverable(queue, folder), [])
            row.pop("image_progress")
            row["capture"]["image"] = {"status": "saved", "revision": 2}
            self.assertEqual(recovery.recoverable(queue, folder), [])

    def test_mismatched_remote_sha_never_overwrites_existing_raster(self):
        with tempfile.TemporaryDirectory() as folder:
            queue, _, _ = fixture(pathlib.Path(folder))
            found = recovery.recoverable(queue, folder)[0]
            with patch.object(recovery.editorial, "queue_read", return_value=(queue, "sha")):
                with patch.object(recovery.github, "current_editorial"):
                    with patch.object(recovery.github, "request", return_value={"sha": "0" * 40}):
                        with patch.object(recovery.github, "save_original") as upload:
                            with patch.object(recovery.editorial, "update_image_receipt") as associate:
                                self.assertEqual(recovery.recover_one(found, None, "auth"),
                                                 "conflicting_original")
                                upload.assert_not_called()
                                associate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
