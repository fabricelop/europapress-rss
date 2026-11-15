#!/usr/bin/env python3
"""Isolated V2 image-on-the-same-chat tests; no real browser or Cloudflare."""
import io
import base64
import itertools
import json
import os
import tempfile
import unittest
from pathlib import Path
from PIL import Image
try:
    from v2.ttendencias import image_same_chat_v2 as same
    from v2.ttendencias import image_intake_v2 as intake
except ModuleNotFoundError:
    import image_same_chat_v2 as same
    import image_intake_v2 as intake

ID="trv2-e94b2984c087ac403753b8c1"
CHAT="https://chatgpt.com/c/6af75cfb-a8ec-83eb-a56e-068f3f313e3b"
ANSWER="Texto editorial verificado sobre un acontecimiento cultural. "*5

def row(revision=1):
    return {"trend_id":ID,"revision":revision,"name":"Acontecimiento",
      "status":"captured_review",
      "capture":{"revision":revision,"chat_url":CHAT,"answer":ANSWER,
                 "sha256":intake.fingerprint(ANSWER)}}

def image():
    import random
    random.seed(10)
    raw=bytes(random.getrandbits(8) for _ in range(1024*576*3))
    img=Image.frombytes("RGB",(1024,576),raw)
    buff=io.BytesIO()
    img.save(buff,format="PNG")
    return buff.getvalue()

class Node:
    def __init__(self,page,selector):self.page=page;self.selector=selector
    @property
    def first(self):return self
    def count(self):return 1 if self.page.composer_available and 'stop-button' not in self.selector else 0
    def is_visible(self):return True
    def is_enabled(self):return True
    def fill(self,text):self.page.filled=text
    def press(self,key):
        assert key=="Enter"
        self.page.send_count+=1
        self.page.last=self.page.filled

class Page:
    url=CHAT
    composer_available=True
    def __init__(self,revision=1):
        self.last=f"TTActualidad V2 Identificador: {ID}. Revisión: {revision}."
        self.send_count=0
        self.filled=""
    def evaluate(self,script):return self.last
    def locator(self,selector):return Node(self,selector)

class SameChatTests(unittest.TestCase):
    def test_image_prompt_dom_lag_does_not_abort_or_resend(self):
        raw=image()
        meta=intake.raster_metadata(raw)
        replies=[
          {"ready":False,"reason":"wrong_image_job_or_conversation"},
          {"ready":False,"reason":"still_generating"},
          {"ready":True,"data":base64.b64encode(raw).decode("ascii"),
           "mime":meta["mime"],"width":meta["width"],"height":meta["height"]}
        ]
        class ProbePage:
            url=CHAT
            def evaluate(self,script):
                self_outer.assertIn('data-user-message-bubble',script)
                return replies.pop(0)
        self_outer=self
        ticks=itertools.count()
        original=same.original_from_same_page(
          ProbePage(),{"command_id":"v2-img-test","conversation_url":CHAT},
          timeout=15,clock=lambda:next(ticks),sleep=lambda _:None)
        self.assertEqual(original,raw)
        self.assertEqual(replies,[])

    def test_wrong_chat_url_is_rejected_immediately(self):
        class WrongPage:
            url="https://chatgpt.com/c/not-the-original"
            def evaluate(self,script):raise AssertionError('Must not probe another chat')
        with self.assertRaisesRegex(RuntimeError,"CHAT_CHANGED"):
            same.original_from_same_page(
              WrongPage(),{"command_id":"v2-img-test","conversation_url":CHAT},
              timeout=5,clock=iter([0,1]).__next__,sleep=lambda _:None)

    def test_wrong_job_that_never_appears_eventually_fails_without_resending(self):
        class WrongPromptPage:
            url=CHAT
            def evaluate(self,script):return {"ready":False,"reason":"wrong_image_job_or_conversation"}
        ticks=itertools.count()
        with self.assertRaisesRegex(RuntimeError,"WRONG_CHAT_JOB"):
            same.original_from_same_page(
              WrongPromptPage(),{"command_id":"v2-img-test","conversation_url":CHAT},
              timeout=12,clock=lambda:next(ticks),sleep=lambda _:None)

    def test_same_chat_one_send_original_and_idempotent_receipt(self):
        p=Page()
        raster=image()
        with tempfile.TemporaryDirectory() as d:
            def upload(job,raw,secret):
                self.assertEqual(secret,"s"*48)
                self.assertIn(job["command_id"],p.filled)
                self.assertEqual(raw,raster)
                self.assertEqual(intake.raster_metadata(raw)["width"],1024)
                return {"status":"saved","trend_id":ID,"revision":1,
                        "path":"v2/ttendencias/generated-images/example.png",
                        "mime":"image/png",
                        "sha256":intake.raster_metadata(raw)["sha256"]}
            args={"root":d,"github_auth":"s"*48,"editorial_preflight":lambda job,auth:True,
                  "raster_get":lambda page,job:raster,"upload":upload}
            saved=same.run(p,row(),**args)
            self.assertEqual(saved["status"],"saved")
            self.assertEqual(p.send_count,1)
            self.assertTrue(list(Path(d,"image-originals").glob("*.png")))
            self.assertEqual(len(list(Path(d,"image-jobs").glob("*.index.json"))),1)
            self.assertEqual(same.run(p,row(),**args)["sha256"],saved["sha256"])
            self.assertEqual(p.send_count,1)

    def test_config_missing_does_not_trigger_imagegen(self):
        p=Page()
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(RuntimeError,"STORAGE_NOT_READY"):
                same.run(p,row(),root=d,github_auth="s"*48,
                    editorial_preflight=lambda job,auth:(_ for _ in ()).throw(
                        RuntimeError("V2_IMAGE_STORAGE_NOT_READY")))
            self.assertEqual(p.send_count,0)
            self.assertFalse(list(Path(d).rglob("*.intent.json")))

    def test_uncertain_prompt_does_not_resend(self):
        p=Page()
        with tempfile.TemporaryDirectory() as d:
            args={"root":d,"github_auth":"s"*48,"editorial_preflight":lambda job,auth:True,
                  "raster_get":lambda page,job:(_ for _ in ()).throw(
                      RuntimeError("image_pending"))}
            with self.assertRaisesRegex(RuntimeError,"image_pending"):
                same.run(p,row(),**args)
            self.assertEqual(p.send_count,1)
            p.last=f"Identificador: {ID}. Revisión: 1."
            with self.assertRaisesRegex(RuntimeError,"SEND_UNCERTAIN_NO_RESEND"):
                same.run(p,row(),**args)
            self.assertEqual(p.send_count,1)

    def test_wrong_tab_or_revision_rejected(self):
        p=Page()
        p.url="https://chatgpt.com/c/12345678-1234-1234-1234-123456789abc"
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaisesRegex(RuntimeError,"CHAT_NOT_VERIFIED"):
                same.run(p,row(),root=d,github_auth="s"*48,editorial_preflight=lambda j,a:True)

if __name__=="__main__":unittest.main()
