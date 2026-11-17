#!/usr/bin/env python3
"""Latest-image replacement and single-file-per-trend GitHub contract tests."""
import base64
import hashlib
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import image_github_v2 as github
import image_intake_v2 as intake
import editorial_run_v2 as editorial

ID="trv2-e94b2984c087ac403753b8c1"
CHAT="https://chatgpt.com/c/6af75cfb-a8ec-83eb-a56e-068f3f313e3b"
ANSWER="Texto editorial contrastado para tendencia original. "*5


def job(revision=1,attempt=1):
    return {"version":1,"trend_id":ID,"revision":revision,"attempt":attempt,
            "command_id":f"v2-img-{ID}-r{revision}-a{attempt}-0123456789abcdef",
            "conversation_url":CHAT,"editorial_sha256":intake.fingerprint(ANSWER)}


def raster(fill=None):
    if fill is None:
        pic=Image.frombytes("RGB",(1024,576),os.urandom(1024*576*3))
    else:
        pic=Image.new("RGB",(1024,576),fill)
    stream=io.BytesIO()
    pic.save(stream,format="PNG")
    return stream.getvalue()


class GitHubFake:
    def __init__(self,revision=1):
        self.items={}
        self.puts=0
        self.deletes=0
        self.ledger={"step":"04_editorial_queue","effects_enabled":False,"items":{
            ID:{"trend_id":ID,"revision":revision,"status":"captured_review",
                "capture":{"answer":ANSWER,"revision":revision,"sha256":intake.fingerprint(ANSWER)}}}}
    def __call__(self,method,path,auth,payload=None):
        if path==github.LEDGER:
            raw=json.dumps(self.ledger).encode()
            encoded=base64.b64encode(raw).decode()
            wrapped=chr(10).join(encoded[i:i+60] for i in range(0,len(encoded),60))
            return {"encoding":"base64","content":wrapped,
                    "sha":github.git_blob_sha(raw)}
        if method=="GET" and path==github.PREFIX:
            return [{"path":name,"sha":value["sha"]} for name,value in self.items.items()]
        if method=="GET":
            return self.items.get(path)
        if method=="PUT":
            self.puts+=1
            assert payload["branch"]==github.BRANCH
            previous=self.items.get(path)
            if previous:
                assert payload.get("sha")==previous["sha"]
            else:
                assert "sha" not in payload
            raw=base64.b64decode(payload["content"],validate=True)
            sha=github.git_blob_sha(raw)
            self.items[path]={"sha":sha}
            return {"content":{"sha":sha},"commit":{"sha":"abc123"}}
        if method=="DELETE":
            self.deletes+=1
            assert self.items[path]["sha"]==payload["sha"]
            del self.items[path]
            return {"commit":{"sha":"delete123"}}
        raise AssertionError(method)


class GitHubImages(unittest.TestCase):
    def test_binary_original_committed_verified_idempotently(self):
        blob=raster()
        fake=GitHubFake()
        saved=github.save_original(job(),blob,"x"*48,send=fake)
        self.assertEqual(fake.puts,1)
        self.assertEqual(saved["sha256"],hashlib.sha256(blob).hexdigest())
        self.assertEqual(saved["status"],"saved")
        self.assertEqual(saved["path"],github.PREFIX+ID+".image")
        self.assertEqual(saved["backend"],"github_v1_style")
        again=github.save_original(job(),blob,"x"*48,send=fake)
        self.assertEqual(again["status"],"already_saved")
        self.assertEqual(fake.puts,1)
        self.assertEqual(len(fake.items),1)

    def test_latest_image_replaces_previous_at_same_stable_path(self):
        fake=GitHubFake()
        first=github.save_original(job(revision=1,attempt=1),raster("red"),"x"*48,send=fake)
        second_blob=raster("blue")
        second=github.save_original(job(revision=2,attempt=1),second_blob,"x"*48,send=fake)
        self.assertEqual(first["path"],second["path"])
        self.assertEqual(second["path"],github.PREFIX+ID+".image")
        self.assertEqual(second["revision"],2)
        self.assertEqual(second["sha256"],hashlib.sha256(second_blob).hexdigest())
        self.assertEqual(fake.puts,2)
        self.assertEqual(len(fake.items),1)
        self.assertNotEqual(first["sha256"],second["sha256"])

    def test_changed_revision_refused_before_any_upload(self):
        fake=GitHubFake(revision=2)
        with self.assertRaisesRegex(ValueError,"EDITORIAL_CHANGED"):
            github.save_original(job(revision=1),raster(),"x"*48,send=fake)
        self.assertEqual(fake.puts,0)

    def test_previous_image_is_replaceable_not_a_conflict(self):
        fake=GitHubFake()
        first=github.save_original(job(attempt=1),raster("red"),"x"*48,send=fake)
        second_blob=raster("blue")
        second=github.save_original(job(attempt=2),second_blob,"x"*48,send=fake)
        self.assertEqual(first["path"],second["path"])
        self.assertEqual(second["status"],"replaced")
        self.assertEqual(fake.puts,2)
        self.assertEqual(len(fake.items),1)

    def test_stale_older_attempt_cannot_replace_a_newer_success(self):
        fake=GitHubFake()
        github.save_original(job(attempt=2),raster("blue"),"x"*48,send=fake)
        before=fake.items[github.PREFIX+ID+".image"]["sha"]
        with self.assertRaisesRegex(RuntimeError,"STALE_ATTEMPT"):
            github.save_original(job(attempt=1),raster("red"),"x"*48,send=fake)
        self.assertEqual(fake.items[github.PREFIX+ID+".image"]["sha"],before)
        self.assertEqual(fake.puts,1)

    def test_legacy_revision_hash_files_are_removed_after_new_receipt(self):
        fake=GitHubFake()
        legacy=github.PREFIX+ID+"-r1-"+"a"*24+".png"
        fake.items[legacy]={"sha":"b"*40}
        stable=github.stable_image_path(ID)
        github.save_original(job(revision=2),raster("green"),"x"*48,send=fake)
        deleted=github.cleanup_superseded_images(ID,stable,"x"*48,send=fake)
        self.assertEqual(deleted,1)
        self.assertNotIn(legacy,fake.items)
        self.assertIn(stable,fake.items)

    def test_saved_receipt_can_be_replaced_by_newer_attempt(self):
        fake=GitHubFake()
        fake.ledger["items"][ID]["capture"]["image"]={
            "status":"saved","revision":1,"attempt":1,
            "command_id":job(attempt=1)["command_id"]}
        image={"status":"saved","revision":1,"attempt":2,
               "command_id":job(attempt=2)["command_id"],"sha256":"c"*64,
               "path":github.stable_image_path(ID)}
        queue=fake.ledger
        with patch.object(editorial,"queue_read",return_value=(queue,"old-sha")):
            with patch.object(editorial,"queue_write") as writer:
                editorial.update_image_receipt(None,"x"*48,ID,1,
                    intake.fingerprint(ANSWER),image)
                writer.assert_called_once()
        self.assertEqual(queue["items"][ID]["capture"]["image"],image)

    def test_newer_saved_receipt_wins_over_slower_older_attempt(self):
        fake=GitHubFake()
        latest={"status":"saved","revision":1,"attempt":3,
                "command_id":job(attempt=3)["command_id"],"sha256":"d"*64}
        fake.ledger["items"][ID]["capture"]["image"]=latest
        queue=fake.ledger
        proposed={"status":"saved","revision":1,"attempt":2,
                  "command_id":job(attempt=2)["command_id"],"sha256":"c"*64}
        with patch.object(editorial,"queue_read",return_value=(queue,"old-sha")):
            with patch.object(editorial,"queue_write") as writer:
                editorial.update_image_receipt(None,"x"*48,ID,1,
                    intake.fingerprint(ANSWER),proposed)
                writer.assert_not_called()
        self.assertEqual(queue["items"][ID]["capture"]["image"],latest)


if __name__=="__main__":
    unittest.main()
