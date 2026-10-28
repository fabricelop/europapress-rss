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


    def test_staged_ready_without_manual_ledger_is_removable(self):
        docs=documents()
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        docs["requests"]={"requests":[{"id":"orphan-ready","name":"Lamine",
            "revision":0,"status":"ready","ready_at":now,
            "delivery_confirmation":"prepared_web"}]}
        docs["trend_prepared"]={"items":[{"id":"orphan-ready","trend_name":"Lamine",
            "revision":0,"generated_at":now,"explanation":"TT#7 Lamine explicada"}]}
        _,trends,_,_=normalise(docs)
        self.assertEqual([(x["id"],x["state"]) for x in trends],[("orphan-ready","Listas")])
        self.assertEqual(trends[0]["body"],"TT#7 Lamine explicada")

    def test_orphan_explained_request_without_manual_ledger(self):
        docs=documents()
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        docs["requests"]={"requests":[{"id":"orphan-ready","name":"Paracetamol",
            "revision":0,"status":"explained","ready_at":now,
            "explained_at":now,"explanation":"TT#9 Texto confirmado"}]}
        docs["trend_prepared"]={"items":[{"id":"orphan-ready","trend_name":"Paracetamol",
            "revision":0,"generated_at":now,"explanation":"TT#9 Texto confirmado"}]}
        _,trends,_,_=normalise(docs)
        self.assertEqual([(x["id"],x["state"]) for x in trends],[("orphan-ready","Listas")])

    def test_staged_ready_blocked_if_active_or_terminal(self):
        docs=documents()
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        docs["requests"]={"requests":[{"id":"ready-1","revision":0,
            "status":"ready","ready_at":now}]}
        docs["trend_prepared"]={"items":[{"id":"ready-1","revision":0,
            "generated_at":now,"explanation":"TT#9 Preparada"}]}
        docs["trend_queue"]={"items":[{"id":"ready-1","revision":0,"status":"preparing"}]}
        _,trends,_,_=normalise(docs)
        self.assertEqual([(x["id"],x["state"]) for x in trends],[("ready-1","En elaboración")])
        docs["trend_queue"]={"items":[]}
        docs["trend_decisions"]={"items":[{"id":"ready-1","revision":0,"status":"published"}]}
        _,trends,_,_=normalise(docs)
        self.assertEqual(trends,[])

    def test_staged_ready_does_not_show_old_or_new_revision(self):
        docs=documents()
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        docs["requests"]={"requests":[{"id":"ready-1","revision":1,"status":"ready"}]}
        docs["trend_prepared"]={"items":[{"id":"ready-1","revision":0,
            "generated_at":now,"explanation":"TT#7 Vieja"}]}
        _,trends,_,_=normalise(docs)
        self.assertEqual(trends,[])


if __name__ == "__main__":
    unittest.main()
