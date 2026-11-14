#!/usr/bin/env python3
"""V2 stores original image blobs in GitHub like V1, without paid storage."""
import base64
import hashlib
import io
import json
import os
import tempfile
import unittest
from PIL import Image

try:
    from v2.ttendencias import image_github_v2 as github
    from v2.ttendencias import image_intake_v2 as intake
except ModuleNotFoundError:
    import image_github_v2 as github
    import image_intake_v2 as intake

ID="trv2-e94b2984c087ac403753b8c1"
CHAT="https://chatgpt.com/c/6af75cfb-a8ec-83eb-a56e-068f3f313e3b"
ANSWER="Texto editorial contrastado para tendencia original. "*5

def job(revision=1):
    return {"version":1,"trend_id":ID,"revision":revision,
            "command_id":f"v2-img-{ID}-r{revision}-a1-0123456789abcdef",
            "conversation_url":CHAT,"editorial_sha256":intake.fingerprint(ANSWER)}

def raster():
    pic=Image.frombytes("RGB",(1024,576),os.urandom(1024*576*3))
    stream=io.BytesIO()
    pic.save(stream,format="PNG")
    return stream.getvalue()

class GitHubFake:
    def __init__(self,revision=1):
        self.items={}
        self.puts=0
        self.ledger={"step":"04_editorial_queue","effects_enabled":False,"items":{
            ID:{"trend_id":ID,"revision":revision,"status":"captured_review",
                "capture":{"answer":ANSWER,"revision":revision}}}}
    def __call__(self,method,path,auth,payload=None):
        if path==github.LEDGER:
            encoded=base64.b64encode(json.dumps(self.ledger).encode()).decode()
            wrapped=chr(10).join(encoded[i:i+60] for i in range(0,len(encoded),60))
            return {"encoding":"base64","content":wrapped}
        if method=="GET":
            return self.items.get(path)
        if method=="PUT":
            self.puts+=1
            assert payload["branch"]==github.BRANCH
            raw=base64.b64decode(payload["content"],validate=True)
            sha=github.git_blob_sha(raw)
            self.items[path]={"sha":sha}
            return {"content":{"sha":sha},"commit":{"sha":"abc123"}}
        raise AssertionError(method)

class GitHubImages(unittest.TestCase):
    def test_binary_original_committed_verified_idempotently(self):
        blob=raster()
        fake=GitHubFake()
        saved=github.save_original(job(),blob,"x"*48,send=fake)
        self.assertEqual(fake.puts,1)
        self.assertEqual(saved["sha256"],hashlib.sha256(blob).hexdigest())
        self.assertEqual(saved["status"],"saved")
        self.assertIn(ID+"-r1-",saved["path"])
        self.assertTrue(saved["path"].startswith("v2/ttendencias/generated-images/"))
        self.assertEqual(saved["backend"],"github_v1_style")
        again=github.save_original(job(),blob,"x"*48,send=fake)
        self.assertEqual(again["status"],"already_saved")
        self.assertEqual(fake.puts,1)

    def test_changed_revision_refused_before_any_upload(self):
        fake=GitHubFake(revision=2)
        with self.assertRaisesRegex(ValueError,"EDITORIAL_CHANGED"):
            github.save_original(job(),raster(),"x"*48,send=fake)
        self.assertEqual(fake.puts,0)

    def test_preexisting_different_original_never_overwritten(self):
        blob=raster()
        fake=GitHubFake()
        path=(github.PREFIX+ID+"-r1-"+hashlib.sha256(blob).hexdigest()[:24]+".png")
        fake.items[path]={"sha":"0"*40}
        with self.assertRaisesRegex(RuntimeError,"EXISTING_RASTER_CONFLICT"):
            github.save_original(job(),blob,"x"*48,send=fake)
        self.assertEqual(fake.puts,0)

    def test_existing_other_image_command_is_not_replaced(self):
        fake=GitHubFake()
        fake.ledger["items"][ID]["capture"]["image"]={
            "status":"saved","command_id":f"v2-img-{ID}-r1-a2-0123456789abcdef"}
        with self.assertRaisesRegex(RuntimeError,"REVISION_ALREADY_BOUND"):
            github.current_editorial(job(),"x"*48,send=fake)
        self.assertEqual(fake.puts,0)

if __name__=="__main__":unittest.main()
