#!/usr/bin/env python3
import hashlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image
from v2.ttendencias import image_intake_v2 as intake

ID="trv2-e94b2984c087ac403753b8c1"
ANSWER="Jordi Wild, tres entrevistas y una silla vacía."
JOB={"trend_id":ID,"revision":1,
     "command_id":"v2-img-"+ID+"-r1-a1-0123456789abcdef",
     "conversation_url":"https://chatgpt.com/c/6af75cfb-a8ec-83eb-a56e-068f3f313e3b",
     "editorial_sha256":intake.fingerprint(ANSWER)}

def original_png():
    # High-entropy pixels; never accept a tiny preview in place of the original.
    pix=os.urandom(1024*576*3)
    img=Image.frombytes("RGB",(1024,576),pix)
    out=io.BytesIO()
    img.save(out,format="PNG")
    return out.getvalue()

class FakeResponse:
    def __init__(self,data):self.data=data
    def __enter__(self):return self
    def __exit__(self,*a):return False
    def read(self,size):return json.dumps(self.data).encode()

class IntakeTests(unittest.TestCase):
    def test_guard(self):
        self.assertTrue(intake.validate_editorial(JOB,{"trend_id":ID,"revision":1,
            "status":"captured_review","capture":{"answer":ANSWER}}))
        with self.assertRaisesRegex(ValueError,"EDITORIAL_CHANGED"):
            intake.validate_editorial(JOB,{"trend_id":ID,"revision":2,"status":"captured_review",
                "capture":{"answer":ANSWER}})
        with self.assertRaisesRegex(ValueError,"JOB_IDENTITY_INVALID"):
            intake.validate_job({**JOB,"command_id":JOB["command_id"].replace("-r1-","-r2-")})

    def test_full_original_receipt_and_replay(self):
        raw=original_png()
        meta=intake.raster_metadata(raw)
        self.assertEqual(meta["width"],1024)
        self.assertEqual(meta["height"],576)
        self.assertGreater(meta["size"],100000)
        with tempfile.TemporaryDirectory() as folder:
            first=intake.persist_original(folder,JOB,raw)
            self.assertEqual(first.read_bytes(),raw)
            self.assertEqual(intake.persist_original(folder,JOB,raw),first)
            changed=original_png()
            with self.assertRaisesRegex(RuntimeError,"LOCAL_ORIGINAL_CONFLICT"):
                intake.persist_original(folder,JOB,changed)
        def upload(req):
            self.assertEqual(req.get_header("X-ttv2-command-id"),JOB["command_id"])
            self.assertEqual(req.get_header("Content-type"),"image/png")
            self.assertEqual(req.get_header("X-ttv2-raster-sha256"),hashlib.sha256(raw).hexdigest())
            return FakeResponse({"ok":True,"status":"saved","trend_id":ID,"revision":1})
        result=intake.upload(JOB,raw,"a"*48,send=upload)
        self.assertEqual(result["status"],"saved")

    def test_preview_and_untrusted_url_rejected(self):
        with self.assertRaisesRegex(ValueError,"ORIGINAL_SIZE_INVALID"):
            intake.raster_metadata(b"preview"*400)
        with self.assertRaisesRegex(ValueError,"JOB_IDENTITY_INVALID"):
            intake.validate_job({**JOB,"conversation_url":"https://evil.example/c/6af75cfb-a8ec-83eb-a56e-068f3f313e3b"})
        with self.assertRaisesRegex(ValueError,"INGEST_SECRET_NOT_CONFIGURED"):
            intake.upload(JOB,original_png(),"bad")

if __name__=="__main__":unittest.main()
