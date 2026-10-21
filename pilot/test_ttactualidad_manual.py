import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location("manual",Path(__file__).with_name("submit_ttactualidad_manual.py"))
manual=importlib.util.module_from_spec(spec)
spec.loader.exec_module(manual)
REQUEST="01234567-89ab-4cde-8fab-0123456789ab"

class ManualSubmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=manual.ROOT
        manual.ROOT=Path(self.temp.name)
        self.addCleanup(lambda:setattr(manual,"ROOT",self.root))
        self.put(manual.PROCESSING,{"items":[{"event_id":"existing","title":"Otra noticia",
            "status":"PROCESSING","revision":1}],"updated_at":"old"})
        self.put(manual.COMPACT,{"project":"TTiTTulares","items":[{"event_id":"existing",
            "title":"Otra noticia","status":"PROCESSING","revision":1}],"count":1})
        self.put(manual.PREPARED,{"items":[{"event_id":"already-ready",
            "title":"Noticia terminada","url":"https://example.org/ready","status":"READY"}]})
    def put(self,path,data):
        p=manual.ROOT/path;p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text(json.dumps(data),encoding="utf-8")
    def get(self,path):
        return json.loads((manual.ROOT/path).read_text(encoding="utf-8"))
    def payload(self,**updates):
        data={"project":"ttittulares","request_id":REQUEST,"title":"Noticia enviada por el usuario",
              "url":"https://example.org/news?a=1#fragment","instructions":"Comprobar fuentes fiables"}
        data.update(updates)
        return data
    def test_add_to_both_queues_and_preserve_existing(self):
        result,eid=manual.apply(self.payload(),"2026-10-19T15:00:00Z")
        self.assertEqual(result,"added")
        self.assertEqual(eid,"manual-"+REQUEST)
        a=self.get(manual.PROCESSING)
        b=self.get(manual.COMPACT)
        self.assertEqual([x["event_id"] for x in a["items"]],[ "existing",eid])
        self.assertEqual([x["event_id"] for x in b["items"]],[ "existing",eid])
        self.assertEqual(b["count"],2)
        self.assertTrue(a["items"][-1]["allow_zero_initial_sources"])
        self.assertTrue(b["items"][-1]["manual_investigation_requested"])
        self.assertEqual(a["items"][-1]["revision"],b["items"][-1]["revision"])
        self.assertEqual(a["items"][-1]["rewrite_request"],"Comprobar fuentes fiables")
        self.assertEqual(a["items"][-1]["url"],"https://example.org/news?a=1")
        self.assertEqual(self.get(manual.PREPARED)["items"][0]["event_id"],"already-ready")
    def test_retry_is_idempotent_and_does_not_mutate(self):
        self.assertEqual(manual.apply(self.payload())[0],"added")
        before=self.get(manual.PROCESSING)
        self.assertEqual(manual.apply(self.payload())[0],"already_received")
        self.assertEqual(self.get(manual.PROCESSING),before)
    def test_duplicate_url_is_not_enqueued_even_with_a_new_request_id(self):
        manual.apply(self.payload())
        later=self.payload(request_id="11234567-89ab-4cde-8fab-0123456789ab",title="Otro título",url="https://example.org/news?a=1#different")
        self.assertEqual(manual.apply(later)[0],"already_exists")
        self.assertEqual(len(self.get(manual.PROCESSING)["items"]),2)
    def test_duplicate_ready_url_is_not_reopened(self):
        req=self.payload(url="https://example.org/ready")
        self.assertEqual(manual.apply(req)[0],"already_exists")
        self.assertEqual(len(self.get(manual.PROCESSING)["items"]),1)
    def test_url_only_is_accepted_as_research_not_verified(self):
        self.assertEqual(manual.apply(self.payload(title=""))[0],"added")
        row=self.get(manual.PROCESSING)["items"][-1]
        self.assertTrue(row["title"].startswith("Investigar noticia del enlace"))
        self.assertEqual(row["source_count"],0)
        self.assertEqual(row["verified_source_count"],0)
    def test_invalid_input_does_not_write(self):
        before=self.get(manual.PROCESSING)
        for payload in (
            self.payload(request_id="broken"),
            self.payload(title="",url=""),
            self.payload(title="ok"),
            self.payload(url="http://example.org/unsafe"),
            self.payload(url="https://user:secret@example.org/"),
            self.payload(project="ttendencias"),
        ):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                manual.apply(payload)
        self.assertEqual(self.get(manual.PROCESSING),before)

if __name__=="__main__":
    unittest.main()
