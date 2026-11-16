#!/usr/bin/env python3
"""Offline parser, fallback, resilience and concurrency tests for V2 source fetchers."""
from __future__ import annotations
import threading
import time
import unittest
from datetime import datetime, timezone
from urllib.parse import urlsplit

from v2.ttittulares.source_catalog_v2 import load_catalog, source_map
from v2.ttittulares.source_fetch_v2 import (
    FetchError, _host_allowed, fetch_all_sources, fetch_one_source,
    parse_html_rows, parse_json_rows, parse_response, parse_xml_rows
)

CATALOG=load_catalog()
BY_NAME=source_map(CATALOG)
NOW=datetime(2026,11,16,10,0,tzinfo=timezone.utc)


def response(body,url,status=200):
    return {"body":body,"http_status":status,"final_url":url,"content_type":"text/plain","bytes":len(body.encode("utf-8"))}


class SourceParsingTests(unittest.TestCase):
    def test_rss_cdata_and_publisher_date_are_extracted(self):
        body="""<rss><channel><item><title><![CDATA[El Gobierno aprueba una nueva medida en el Parlamento]]></title>
        <link>https://elpais.com/noticias/medida-123</link>
        <pubDate>Mon, 16 Nov 2026 09:30:00 GMT</pubDate></item></channel></rss>"""
        rows=parse_xml_rows(body,"EL PAÍS",BY_NAME["EL PAÍS"],
                            "https://feeds.elpais.com/mrss-s/test.xml",NOW)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]["title"],"El Gobierno aprueba una nueva medida en el Parlamento")
        self.assertEqual(rows[0]["published_at"],"2026-11-16T09:30:00Z")
        self.assertEqual(rows[0]["publication_date_source"],"publisher_feed")

    def test_atom_link_href_and_updated_is_not_publication(self):
        body="""<feed xmlns="http://www.w3.org/2005/Atom"><entry>
        <title>El Gobierno aprueba una nueva medida tras el debate en el Parlamento</title>
        <link rel="alternate" href="https://elpais.com/noticias/medida-123"/>
        <updated>2026-11-16T09:50:00Z</updated></entry></feed>"""
        rows=parse_xml_rows(body,"EL PAÍS",BY_NAME["EL PAÍS"],
                            "https://feeds.elpais.com/test.xml",NOW)
        self.assertEqual(len(rows),1)
        self.assertNotIn("published_at",rows[0])

    def test_google_news_date_is_never_trusted_and_suffix_is_trimmed(self):
        body="""<rss><channel><item><title>El Gobierno aprueba una medida tras el debate - Reuters</title>
        <link>https://news.google.com/rss/articles/12345</link>
        <pubDate>Mon, 16 Nov 2026 09:59:00 GMT</pubDate></item></channel></rss>"""
        rows=parse_xml_rows(body,"Reuters Radar",BY_NAME["Reuters Radar"],
                            "https://news.google.com/rss/search?q=site%3Areuters.com",NOW)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]["title"],"El Gobierno aprueba una medida tras el debate")
        self.assertNotIn("published_at",rows[0])

    def test_html_anchor_extractor_handles_nested_markup_and_rejects_external_hosts(self):
        body="""<html><body>
        <a href="/noticias/123"><strong>El Gobierno aprueba una nueva medida</strong> tras el debate en el Parlamento</a>
        <a href="https://example.net/ad/123">Este titular externo es suficientemente largo para superar el mínimo de texto permitido</a>
        <a href="/short">Corto</a></body></html>"""
        rows=parse_html_rows(body,"Europa Press",BY_NAME["Europa Press"],"https://www.europapress.es/noticias/")
        self.assertEqual(len(rows),1)
        self.assertTrue(rows[0]["url"].startswith("https://www.europapress.es/"))

    def test_json_recent_fallback(self):
        body='{"items":[{"title":"El Gobierno aprueba una nueva medida en el Parlamento","url":"https://www.europapress.es/noticias/123","published_at":"2026-11-16T09:00:00Z"}]}'
        rows=parse_json_rows(body,"Europa Press",BY_NAME["Europa Press"],NOW)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]["publication_date_source"],"publisher_feed")
        self.assertEqual(parse_response(body,"Europa Press",BY_NAME["Europa Press"],
                                       "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/recent.json",NOW),rows)

    def test_json_cross_domain_url_is_rejected(self):
        body='{"items":[{"title":"El Gobierno aprueba una nueva medida en el Parlamento","url":"https://example.net/123"}]}'
        self.assertEqual(parse_json_rows(body,"Europa Press",BY_NAME["Europa Press"],NOW),[])

    def test_sport_filter_excludes_routine_minor_competitions(self):
        body="""<html><a href="/noticias/uno">Carlos Alcaraz gana Wimbledon tras una gran final en Londres</a>
        <a href="/noticias/dos">El equipo juvenil gana el grupo 2 de Segunda RFEF esta jornada</a></html>"""
        rows=parse_html_rows(body,"AS",BY_NAME["AS"],"https://as.com/ultimas-noticias/")
        self.assertEqual(len(rows),1)
        self.assertIn("Alcaraz",rows[0]["title"])


class SourceNetworkAdapterTests(unittest.TestCase):
    def test_source_url_allowlist_rejects_http_and_unknown_hosts(self):
        self.assertTrue(_host_allowed("https://www.europapress.es/noticias/","Europa Press",CATALOG))
        self.assertTrue(_host_allowed("https://raw.githubusercontent.com/fabricelop/europapress-rss/main/recent.json","Europa Press",CATALOG))
        self.assertFalse(_host_allowed("http://www.europapress.es/noticias/","Europa Press",CATALOG))
        self.assertFalse(_host_allowed("https://evil.example/noticias/","Europa Press",CATALOG))

    def test_fallback_advances_after_http_failure_and_preserves_source_identity(self):
        primary=BY_NAME["Europa Press"]["url"]
        fallback="https://raw.githubusercontent.com/fabricelop/europapress-rss/main/recent.json"
        body='{"items":[{"title":"El Gobierno aprueba una nueva medida tras debate parlamentario","url":"https://www.europapress.es/noticias/123"}]}'
        calls=[]
        def fake(url,source,timeout):
            calls.append(url)
            if url==primary:
                raise FetchError("http_error","HTTP 503",503)
            if url==fallback:
                return response(body,url)
            return response("<html></html>",url)
        rows,status=fetch_one_source("Europa Press",catalog=CATALOG,now=NOW,fetcher=fake)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]["source"],"Europa Press")
        self.assertEqual(rows[0]["source_type"],"general")
        self.assertTrue(status["ok"])
        self.assertTrue(status["fallback_used"])
        self.assertEqual(status["fallback_depth"],1)
        self.assertEqual(calls[:2],[primary,fallback])

    def test_source_fallbacks_keep_same_family_and_google_news_not_a_second_vote(self):
        seen=[]
        def fake(url,source,timeout):
            seen.append((url,source))
            raise FetchError("http_error","offline",503)
        rows,status=fetch_one_source("Antena 3 Noticias",catalog=CATALOG,now=NOW,fetcher=fake)
        self.assertEqual(rows,[])
        self.assertFalse(status["ok"])
        self.assertEqual({name for _,name in seen},{"Antena 3 Noticias"})
        self.assertTrue(any("news.google.com" in url for url,_ in seen))
        self.assertEqual(status["family"],"Atresmedia")

    def test_ser_falls_back_from_stale_publisher_page_to_google_news(self):
        stale="""<html><a href="/2026/11/15/story">La Cadena SER publica una noticia antigua de prueba sobre política nacional</a></html>"""
        google="""<rss><channel><item><title>La Cadena SER publica una noticia reciente de prueba sobre política nacional - Cadena SER</title>
        <link>https://news.google.com/rss/articles/12345</link><pubDate>Mon, 16 Nov 2026 09:59:00 GMT</pubDate></item></channel></rss>"""
        primary=BY_NAME["Cadena SER"]["url"]
        google_url=next(x for x in __import__("v2.ttittulares.source_catalog_v2",fromlist=["fallback_chain"]).fallback_chain("Cadena SER",catalog=CATALOG) if "news.google.com" in x)
        def fake(url,source,timeout):
            if url==primary:return response(stale,url)
            if url==google_url:return response(google,url)
            raise FetchError("not_found","not found",404)
        rows,status=fetch_one_source("Cadena SER",catalog=CATALOG,now=NOW,fetcher=fake)
        self.assertTrue(status["ok"])
        self.assertTrue(status["fallback_used"])
        self.assertTrue(all(x["url"].startswith("https://news.google.com/") for x in rows))
        self.assertNotIn("published_at",rows[0])

    def test_failed_source_does_not_stop_other_parallel_sources(self):
        names=["Europa Press","EL PAÍS","La Vanguardia"]
        def fake(url,source,timeout):
            if source=="EL PAÍS" and url==BY_NAME[source]["url"]:
                raise FetchError("http_error","HTTP 500",500)
            if source=="EL PAÍS":
                return response("""<rss><channel><item><title>El Gobierno aprueba una nueva medida en el Parlamento</title>
                <link>https://elpais.com/noticias/1</link></item></channel></rss>""",url)
            if source=="Europa Press":
                return response('{"items":[{"title":"El Gobierno aprueba una nueva medida en el Parlamento","url":"https://www.europapress.es/noticias/1"}]}',url)
            return response("""<rss><channel><item><title>El Gobierno aprueba una nueva medida en el Parlamento</title>
                <link>https://www.lavanguardia.com/noticias/1</link></item></channel></rss>""",url)
        result=fetch_all_sources(catalog=CATALOG,source_names=names,workers=3,now=NOW,fetcher=fake)
        self.assertEqual(result["metrics"]["successful_sources"],3)
        self.assertEqual(len(result["source_statuses"]),3)
        self.assertEqual(len(result["rows"]),3)

    def test_worker_limit_is_bounded(self):
        names=["Europa Press","EL PAÍS","La Vanguardia","Cadena SER","RTVE"]
        lock=threading.Lock()
        active=0
        maximum=0
        def fake(url,source,timeout):
            nonlocal active,maximum
            with lock:
                active+=1
                maximum=max(maximum,active)
            time.sleep(0.025)
            with lock:
                active-=1
            if source=="Europa Press":
                return response('{"items":[{"title":"El Gobierno aprueba una nueva medida en el Parlamento","url":"https://www.europapress.es/noticias/1"}]}',url)
            if source=="EL PAÍS":
                return response("<rss><channel><item><title>El Gobierno aprueba una nueva medida en el Parlamento</title><link>https://elpais.com/noticias/1</link></item></channel></rss>",url)
            if source=="La Vanguardia":
                return response("<rss><channel><item><title>El Gobierno aprueba una nueva medida en el Parlamento</title><link>https://www.lavanguardia.com/noticias/1</link></item></channel></rss>",url)
            if source=="Cadena SER":
                # use Google news fallback-like success; the stale-page rule is not applied there
                return response("<rss><channel><item><title>La noticia de Cadena SER tiene una descripción suficientemente larga para pasar el filtro</title><link>https://news.google.com/rss/articles/55</link></item></channel></rss>",url)
            return response('<html><a href="/noticias/1">RTVE publica una noticia de actualidad suficientemente larga para superar el filtro mínimo</a></html>',url)
        result=fetch_all_sources(catalog=CATALOG,source_names=names,workers=3,now=NOW,fetcher=fake)
        self.assertGreaterEqual(maximum,2)
        self.assertLessEqual(maximum,3)
        self.assertEqual(result["metrics"]["parallel_workers"],3)

    def test_unknown_source_is_rejected_before_network(self):
        called=[]
        with self.assertRaises(ValueError):
            fetch_one_source("No existe",catalog=CATALOG,fetcher=lambda *args: called.append(args))
        self.assertEqual(called,[])


if __name__=="__main__":
    unittest.main(verbosity=2)
