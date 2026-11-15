import unittest
from v2.ttendencias import web_top30_v2 as web


class ReProjectionTest(unittest.TestCase):
    def sample(self):
        names = [f"Trend{i}" for i in range(30)]
        ids = ["trv2-" + format(i+1,"024x") for i in range(30)]
        h = {"step":"03_movement","country":"ES","observed_at":"2026-11-15T14:00:00Z",
             "top30":names,"topics":{name:{"name":name,"rank":i+1,"active":True,"trend_id":ids[i]} for i,name in enumerate(names)}}
        q = {"step":"04_editorial_queue","source_observed_at":h["observed_at"],"effects_enabled":False,
             "items":{k:{"trend_id":k,"status":"pending","revision":1} for k in ids}}
        return h,q,ids[0]

    def test_previous_explanation_visible_until_new_capture(self):
        h,q,id = self.sample()
        sha="a"*64
        cap={"revision":1,"verified_complete":True,"answer":"Noticia anterior verificada. "*5,
             "sha256":"b"*64,"captured_at":"2026-11-13T20:31:00Z",
             "image":{"status":"saved","revision":1,"backend":"github_v1_style","sha256":sha,
                      "mime":"image/png","command_id":"v2-img-"+id+"-r1-a1-1234567890abcd12",
                      "path":"v2/ttendencias/generated-images/"+id+"-r1-"+sha[:24]+".png"}}
        row=q["items"][id]
        row.update(status="review_pending",revision=2,previous_revision=1,previous_status="captured_review",previous_capture=cap)
        first=web.build(h,q)["items"][0]
        self.assertTrue(first["re_in_progress"])
        self.assertEqual(first["status"],"explicada")
        self.assertEqual(first["revision"],1)
        self.assertTrue(first["image_available"])
        row.update(status="captured_review",capture={"revision":2,"verified_complete":True,
           "answer":"Explicación nueva verificada. "*6,"sha256":"c"*64})
        new=web.build(h,q)["items"][0]
        self.assertEqual(new["revision"],2)
        self.assertEqual(new["status"],"explicada")
        self.assertFalse(new["image_available"])
        self.assertFalse(new["re_in_progress"])


if __name__ == "__main__":unittest.main()
