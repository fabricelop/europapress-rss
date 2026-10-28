"""No network or GitHub credentials are needed for these data-contract tests."""
import datetime as dt
import unittest
from TTActualidad import FILES, normalise, date

def documents():
    return {key:{"items":[]} for key in FILES}

class EditorialDesktopTests(unittest.TestCase):
    def test_source_paths_are_canonical(self):
        self.assertEqual(FILES["news_queue"], "ttittulares/editorial-queue.json")
        self.assertEqual(FILES["trend_queue"], "trends/editorial-queue.json")
        self.assertEqual(FILES["pub_events"], "pilot/ttactualidad-publication-events.json")

    def test_news_ready_vs_terminal_decisions(self):
        docs=documents()
        docs["prepared"]={"items":[
          {"event_id":"n1","revision":1,"title":"Noticias abierta","tweet":{"text":"Texto confirmado"}},
          {"event_id":"n2","revision":1,"title":"Noticia publicada"},
          {"event_id":"n3","revision":1,"title":"Reelaboración activa","rewrite_pending":True}
        ]}
        docs["decisions"]={"items":[{"event_id":"n2","revision":1,"status":"published"}]}
        docs["requests"]={"requests":[]}
        news,trends,top,pubs=normalise(docs)
        self.assertEqual([n["id"] for n in news if n["state"]=="Listas"],["n1"])

    def test_working_and_trends(self):
        docs=documents()
        docs["requests"]={"requests":[{"id":"t1","revision":1,"name":"Tendencia Uno"}]}
        docs["trend_queue"]={"items":[{"id":"t1","revision":1,"status":"preparing","name":"Tendencia Uno"}]}
        docs["news_queue"]={"items":[{"event_id":"n1","revision":2,"status":"PROCESSING","title":"Noticia Uno"}]}
        docs["recent"]={"items":[{"name":"Tendencia Uno","rank":2}]}
        news,trends,top,pubs=normalise(docs)
        self.assertEqual([n["state"] for n in news],["En elaboración"])
        self.assertEqual([x["state"] for x in trends],["En elaboración"])
        self.assertEqual(top[0]["rank"],2)

    def test_24h_publications_only_verified_unique(self):
        docs=documents()
        t=dt.datetime.now(dt.timezone.utc)
        old=(t-dt.timedelta(days=2)).isoformat()
        recent=(t-dt.timedelta(minutes=4)).isoformat()
        docs["pub_events"]={"items":[
          {"project":"ttittulares","event_id":"1","revision":1,"at":recent},
          {"project":"ttittulares","event_id":"1","revision":1,"at":recent},
          {"project":"ttendencias","event_id":"2","revision":1,"at":recent},
          {"project":"ttendencias","event_id":"3","revision":1,"at":old}
        ]}
        _,_,_,pubs=normalise(docs)
        self.assertEqual(pubs,{"ttittulares":1,"ttendencias":1})

    def test_parse_timestamp_without_timezone(self):
        d=date("2026-10-28T17:00:00")
        self.assertIsNotNone(d.tzinfo)

if __name__ == "__main__":
    unittest.main()
