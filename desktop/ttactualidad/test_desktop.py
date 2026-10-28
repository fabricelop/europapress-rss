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


    def test_windows_matches_iphone_no_staged_only_ghosts(self):
        docs=documents()
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        docs["requests"]={"requests":[{"id":"orphan","revision":0,"status":"explained","explanation":"Texto"}]}
        docs["trend_prepared"]={"items":[{"id":"orphan","revision":0,"explanation":"Texto","generated_at":now}]}
        self.assertEqual(normalise(docs)[1],[])

    def test_published_request_closes_older_manual_explanation(self):
        docs=documents()
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        docs["manual"]={"items":[{"id":"ministerio","status":"explained","revision":0,
            "name":"Ministerio de Transportes","explained_at":now,"explanation":"Texto"}]}
        docs["requests"]={"requests":[{"id":"ministerio","status":"published",
            "revision":0,"explanation":"Texto","published_at":now}]}
        self.assertEqual(normalise(docs)[1],[])

    def test_terminal_tremending_cannot_resurrect_from_source(self):
        docs=documents()
        docs["tremending"]={"items":[
            {"id":"tremending-closed","status":"deleted","title":"Retirado"},
            {"id":"tremending-active","status":"ready","title":"Vigente","url":"https://www.publico.es/tremending/test"}]}
        news=normalise(docs)[0]
        self.assertEqual([x["id"] for x in news if x["state"]=="Tremending"],["tremending-active"])

    def test_active_request_visible_when_queue_does_not_include_it(self):
        docs=documents()
        docs["requests"]={"requests":[{"id":"t1","status":"preparing","revision":0,
            "name":"Preparando"}]}
        self.assertEqual([(x["id"],x["state"]) for x in normalise(docs)[1]],[("t1","En elaboración")])

    def test_top30_matches_rank_and_manual_id(self):
        docs=documents()
        docs["recent"]={"items":[{"rank":12,"name":"Tendencia nueva"}]}
        top=normalise(docs)[2]
        self.assertEqual(top[0]["rank"],12)
        self.assertTrue(top[0]["id"].startswith("manual-"))
        self.assertEqual(len(top[0]["id"]),39)
        self.assertEqual(top[0]["trend_status"],"PREPARACIÓN MANUAL")

    def test_top30_uses_same_normalized_explanation_as_iphone(self):
        docs=documents()
        docs["recent"]={"items":[{"rank":3,"name":"YA ESTÁ BIEN"}]}
        docs["explained"]={"items":[{"display_name":"ya esta bien",
            "explanation":"Explicación anterior","explained_at":"2026-10-28T10:00:00Z"}]}
        top=normalise(docs)[2]
        self.assertEqual(top[0]["body"],"Explicación anterior")

    def test_request_closed_suppresses_manual_even_if_staged_present(self):
        docs=documents()
        now=dt.datetime.now(dt.timezone.utc).isoformat()
        docs["requests"]={"requests":[{"id":"x","revision":0,"status":"deleted"}]}
        docs["manual"]={"items":[{"id":"x","revision":0,"status":"explained",
            "explanation":"Old","explained_at":now}]}
        docs["trend_prepared"]={"items":[{"id":"x","revision":0,"explanation":"Old","generated_at":now}]}
        self.assertEqual(normalise(docs)[1],[])


if __name__ == "__main__":
    unittest.main()
