#!/usr/bin/env python3
"""Regression tests for isolated TTiTTulares V2 radar ingestion; all fixtures are synthetic."""
from __future__ import annotations
import copy
import unittest
from datetime import datetime, timedelta, timezone

from v2.ttittulares.source_catalog_v2 import load_catalog, fallback_chain
from v2.ttittulares.content_filters_v2 import content_filter_reason, routine_lottery_result, sport_important
from v2.ttittulares.source_publication_v2 import parse_publication_date, feed_publication
from v2.ttittulares.identity_v2 import (
    evidence_title_eligible, has_independent_evidence_consensus, same_fact,
    fingerprint, tokens, events_match, best_match
)
from v2.ttittulares.radar_ingest_v2 import (
    ingest_scan, canonical_url, _TokenLookup, _index_match
)

BASE = datetime(2026, 11, 16, 10, 0, tzinfo=timezone.utc)
TITLE = "El Gobierno aprueba una nueva medida tras el debate en el Parlamento"
CATALOG = load_catalog()
GENERAL = [x["name"] for x in CATALOG["sources"] if x["type"] == "general"]
BY_NAME = {x["name"]: x for x in CATALOG["sources"]}


def make_row(source, title=TITLE, suffix="1", **extra):
    definition = BY_NAME[source]
    domain = definition["domain"]
    url = extra.pop("url", f"https://{domain}/noticias/{suffix}")
    row = {"source": source, "title": title, "url": url}
    row.update(extra)
    return row


def statuses(ok_names=None):
    ok_names = set(ok_names if ok_names is not None else GENERAL)
    return [
        {"source": x["name"], "ok": x["name"] in ok_names,
         "items": 1 if x["name"] in ok_names else 0,
         "url": x["url"], "latency_ms": 120,
         "error": None if x["name"] in ok_names else "fixture_unavailable"}
        for x in CATALOG["sources"]
    ]


def run(rows, previous=None, index=None, at=BASE, source_statuses=None):
    return ingest_scan(rows, source_statuses if source_statuses is not None else statuses(),
                       previous, index, now=at, catalog=CATALOG)


def ready_index(title, event_id="ttn2-0123456789abcdef01234567", families=None):
    return {"schema_version": 1, "project": "ttittulares-v2", "items": {
        event_id: {
            "event_id": event_id, "canonical_title": title, "aliases": [],
            "canonical_urls": ["https://example.org/original"],
            "source_families": list(families or ["Old Family A", "Old Family B"]),
            "fact_tokens": sorted(tokens(title)), "current_revision": 1,
            "status": "ready", "terminal_status": None, "editorial_created": True,
            "revision_refs": [{"revision": 1, "reason": "initial", "status": "ready",
                               "requested_at": "2026-11-15T10:00:00Z",
                               "editorial_job_id": event_id + "-r1-editorial"}]
        }
    }}


class IndexedMatchingParityTests(unittest.TestCase):
    def test_lookup_never_excludes_possible_title_or_variant_match(self):
        titles = [
            "El Ejecutivo anuncia una nueva reforma del transporte ferroviario",
            "El Gobierno aprueba una nueva medida tras el debate en el Parlamento",
            "La selección española vence a Italia en el partido amistoso",
            "Una tormenta provoca grandes inundaciones en el sur de Francia",
            "Los trabajadores negocian un aumento salarial en el sector público",
            "El tribunal investiga una trama de corrupción en el ministerio",
            "La justicia confirma la sanción al club deportivo de Sevilla",
            "El Congreso debate una ley de protección de los trabajadores",
        ]
        events = [{"event_id": f"ttn2-{i:024x}", "canonical_title": title,
                   "appearances": [{"title": title.replace("El ", "Un ")}]}
                  for i, title in enumerate(titles)]
        lookup = _TokenLookup(events)
        for title in titles + [
            "El Gobierno anuncia una reforma del transporte ferroviario",
            "Tribunal confirma una sanción al club deportivo sevillano",
            "Gobierno y trabajadores negocian una reforma salarial",
        ]:
            probable = {x["event_id"] for x in lookup.candidates(title)}
            for event in events:
                direct = best_match(title, [event])[0] is not None
                self.assertFalse(direct and event["event_id"] not in probable,
                                 (title, event["canonical_title"]))
            for event in events:
                if events_match({"canonical_title": title, "appearances": []}, event):
                    self.assertIn(event["event_id"], probable)

    def test_index_lookup_matches_full_scan_for_urls_and_text(self):
        titles = [
            "El Gobierno aprueba la reforma del sector ferroviario",
            "El tribunal investiga una trama de corrupción ministerial",
            "La selección española vence a Italia en partido amistoso",
        ]
        items = {}
        for i, title in enumerate(titles):
            key = f"ttn2-{i:024x}"
            items[key] = ready_index(title, event_id=key)["items"][key]
        lookup = _TokenLookup()
        from v2.ttittulares.identity_v2 import comparable_url
        for item in items.values():
            lookup.add(item, variants=[item["canonical_title"]] + item["aliases"],
                       urls=[comparable_url(url) for url in item["canonical_urls"]])
        for row in [
            {"title": "El Congreso aprueba una reforma del sector ferroviario",
             "canonical_url": "https://other.example/a"},
            {"title": "Partido de fútbol en el estadio de Madrid",
             "canonical_url": "https://example.org/original"},
            {"title": "La selección gana un partido amistoso frente a Italia",
             "canonical_url": "https://other.example/b"},
            {"title": "Nueva noticia distinta sobre transporte marítimo",
             "canonical_url": "https://other.example/c"},
        ]:
            self.assertEqual(_index_match(row, items, lookup), _index_match(row, items))


class SourceCatalogTests(unittest.TestCase):
    def test_catalog_counts_and_families_are_exact_v1_port(self):
        general = [x for x in CATALOG["sources"] if x["type"] == "general"]
        sport = [x for x in CATALOG["sources"] if x["type"] == "sport"]
        discovery = [x for x in CATALOG["sources"] if x["type"] in ("discovery", "social")]
        self.assertEqual((len(general), len({x["family"] for x in general})), (19, 16))
        self.assertEqual(len(sport), 5)
        self.assertEqual(len(discovery), 3)
        self.assertEqual(CATALOG["policy"]["minimum_general_families"], 4)
        self.assertFalse(CATALOG["policy"]["discovery_counts_toward_general_threshold"])

    def test_fallbacks_stay_inside_one_source_family(self):
        chain = fallback_chain("EFE", catalog=CATALOG)
        self.assertTrue(chain[0].startswith("https://efe.com/espana/"))
        self.assertTrue(any("news.google.com" in url for url in chain))
        self.assertTrue(any("when%3A24h" in url or "when%3A24h" in url for url in chain))
        self.assertEqual(BY_NAME["EFE"]["family"], "EFE")


class SourceFilterTests(unittest.TestCase):
    def test_daily_horoscope_is_filtered_but_reporting_about_astrology_is_not(self):
        self.assertEqual(content_filter_reason("Tu horóscopo diario: lunes 16 de noviembre"), "astrology_daily")
        self.assertEqual(content_filter_reason("Predicciones para Aries hoy: amor, dinero y salud"), "astrology_daily")
        self.assertIsNone(content_filter_reason("Un estudio científico analiza por qué creemos en los horóscopos"))

    def test_routine_lottery_draw_filtered_but_material_lottery_story_is_not(self):
        self.assertTrue(routine_lottery_result("Comprobar resultado de Euromillones de hoy: combinación ganadora"))
        self.assertFalse(routine_lottery_result("Investigan un fraude en el sorteo de Euromillones"))
        
    def test_sport_scope_uses_v1_priority_filter(self):
        self.assertTrue(sport_important("Carlos Alcaraz gana Wimbledon"))
        self.assertFalse(sport_important("El equipo juvenil gana el grupo 2 de Segunda RFEF"))

    def test_publisher_date_does_not_fall_back_to_updated_or_google_aggregator_date(self):
        self.assertIsNone(feed_publication("<entry><updated>2026-11-16T09:00:00Z</updated></entry>", BASE))
        self.assertEqual(feed_publication(
            "<item><pubDate>Mon, 16 Nov 2026 09:00:00 GMT</pubDate><updated>2026-11-16T10:00:00Z</updated></item>", BASE),
            "2026-11-16T09:00:00Z")
        self.assertIsNone(parse_publication_date("2026-11-16T10:10:00", BASE))
        self.assertIsNone(parse_publication_date("2026-11-16T11:00:00Z", BASE))

    def test_tracking_query_is_not_part_of_article_identity(self):
        self.assertEqual(canonical_url("https://elpais.com/noticia/123?utm_source=x&gclid=abc"),
                         canonical_url("https://elpais.com/noticia/123"))


class QuorumAndGroupingTests(unittest.TestCase):
    def test_four_independent_general_families_make_one_eligible_candidate(self):
        rows = [make_row(name, suffix=str(i)) for i, name in enumerate(GENERAL[:4])]
        result = run(rows)
        self.assertEqual(len(result["newly_eligible"]), 1)
        event = result["newly_eligible"][0]
        self.assertEqual(event["source_count"], 4)
        self.assertEqual(event["status"], "eligible")
        self.assertEqual(event["revision"], 1)
        self.assertTrue(event["editorial_job_id"].endswith("-r1-editorial"))
        self.assertEqual(result["radar_state"]["effects_enabled"], False)

    def test_five_outlets_from_two_groups_do_not_count_as_four_families(self):
        names = ["Antena 3 Noticias", "laSexta Noticias", "Onda Cero",
                 "Telecinco Noticias", "Noticias Cuatro"]
        result = run([make_row(name, suffix=str(i)) for i, name in enumerate(names)])
        self.assertEqual(result["newly_eligible"], [])
        event = next(iter(result["radar_state"]["items"].values()))
        self.assertEqual(event["outlet_count"], 5)
        self.assertEqual(event["source_count"], 2)
        self.assertEqual(event["status"], "monitoring")

    def test_discovery_sources_help_the_scan_but_never_vote(self):
        names = GENERAL[:3] + ["Reuters Radar", "AP Radar"]
        result = run([make_row(name, suffix=str(i)) for i, name in enumerate(names)])
        self.assertEqual(result["newly_eligible"], [])
        event = next(iter(result["radar_state"]["items"].values()))
        self.assertEqual(event["source_count"], 3)
        self.assertEqual(event["discovery_source_count"], 2)

    def test_publico_social_discovery_does_not_count_as_general(self):
        names = GENERAL[:3] + ["Público · Tremending"]
        result = run([make_row(name, suffix=str(i)) for i, name in enumerate(names)])
        event = next(iter(result["radar_state"]["items"].values()))
        self.assertEqual(event["source_count"], 3)
        self.assertEqual(event["social_sources"], ["Público · Tremending"])
        self.assertEqual(result["newly_eligible"], [])

    def test_rephrased_ceuta_titles_keep_v1_connected_evidence_regression(self):
        titles = [
            ("EL PAÍS", "El Gobierno ultima el cese del delegado en Ceuta"),
            ("laSexta Noticias", "El Ejecutivo ultima el cese del delegado del Gobierno en Ceuta"),
            ("Público", "El delegado del Gobierno en Ceuta abandona el cargo"),
            ("Europa Press", "El Gobierno prepara el relevo del delegado del Gobierno en Ceuta tras comunicar su deseo de no continuar en el cargo")
        ]
        result = run([make_row(source, title, suffix=str(i)) for i,(source,title) in enumerate(titles)])
        self.assertEqual(len(result["newly_eligible"]), 1)
        self.assertEqual(result["newly_eligible"][0]["source_count"], 4)

    def test_mixed_facts_do_not_form_a_false_consensus(self):
        titles = [
            ("Europa Press", "Al menos dos muertos y ocho heridos en Kiev tras otra noche de ataques rusos con drones y misiles"),
            ("EL PAÍS", "Rusia boicotea la ayuda humanitaria a la ciudad ocupada de Oleshki y dispara el riesgo de hambruna"),
            ("La Vanguardia", "Guerra de Ucrania"),
            ("Cadena SER", "¿Estamos en guerra?")
        ]
        result = run([make_row(source,title,suffix=str(i)) for i,(source,title) in enumerate(titles)])
        self.assertEqual(result["newly_eligible"], [])
        self.assertGreaterEqual(len(result["radar_state"]["items"]), 2)

    def test_generic_section_titles_cannot_supply_quorum(self):
        titles = ["Portada de EL MUNDO del lunes 16 de noviembre de 2026"] * 4
        result = run([make_row(source,title,suffix=str(i)) for i,(source,title) in enumerate(zip(GENERAL[:4],titles))])
        self.assertEqual(result["newly_eligible"], [])
        self.assertFalse(evidence_title_eligible(titles[0]))

    def test_same_source_repeated_urls_are_only_one_appearance(self):
        rows = [make_row("EL PAÍS", suffix="a"), make_row("EL PAÍS", suffix="b"),
                make_row("Europa Press", suffix="c"), make_row("La Vanguardia", suffix="d")]
        result = run(rows)
        event = next(iter(result["radar_state"]["items"].values()))
        self.assertEqual(event["source_count"], 3)
        self.assertEqual(len([x for x in event["appearances"] if x["source"]=="EL PAÍS"]), 1)
        self.assertEqual(result["newly_eligible"], [])

    def test_sport_headlines_are_discovered_but_do_not_satisfy_general_quorum(self):
        result = run([make_row("AS","Carlos Alcaraz gana Wimbledon","sport-1")])
        event = next(iter(result["radar_state"]["items"].values()))
        self.assertEqual(event["sport_source_count"], 1)
        self.assertEqual(event["source_count"], 0)
        self.assertEqual(result["newly_eligible"], [])
        filtered = run([make_row("AS","El equipo juvenil gana el grupo 2 de Segunda RFEF","sport-2")])
        self.assertEqual(filtered["accepted_rows"], [])
        self.assertEqual(filtered["filtered"][0]["reason"], "sport_not_in_priority_scope")


class LifecycleTests(unittest.TestCase):
    def test_horoscope_and_routine_draw_rows_never_enter_radar(self):
        rows = [make_row("EL PAÍS","Tu horóscopo diario: lunes 16 de noviembre","h"),
                make_row("Europa Press","Comprobar resultado de Euromillones de hoy: combinación ganadora","l")]
        result = run(rows)
        self.assertEqual(result["accepted_rows"], [])
        self.assertEqual({x["reason"] for x in result["filtered"]}, {"astrology_daily","routine_lottery_result"})
        self.assertEqual(result["radar_state"]["items"], {})

    def test_rediscovery_does_not_reset_original_24h_ttl(self):
        rows = [make_row(name,suffix=str(i)) for i,name in enumerate(GENERAL[:3])]
        first=run(rows,at=BASE)
        event_id=next(iter(first["radar_state"]["items"]))
        second=run(rows,previous=first["radar_state"],index=first["news_index"],
                   at=BASE+timedelta(hours=23))
        event=second["radar_state"]["items"][event_id]
        self.assertEqual(event["first_seen_at"], BASE.isoformat().replace("+00:00","Z"))
        self.assertEqual(event["status"], "monitoring")
        third=run(rows,previous=second["radar_state"],index=second["news_index"],
                  at=BASE+timedelta(hours=24))
        self.assertEqual(third["radar_state"]["items"][event_id]["status"], "archived")
        self.assertEqual(third["news_index"]["items"][event_id]["status"], "archived")
        self.assertEqual(third["newly_eligible"], [])

    def test_candidate_identity_is_stable_across_scans(self):
        rows = [make_row(name,suffix=str(i)) for i,name in enumerate(GENERAL[:3])]
        first=run(rows,at=BASE)
        event_id=next(iter(first["radar_state"]["items"]))
        second=run(rows,previous=first["radar_state"],index=first["news_index"],
                   at=BASE+timedelta(minutes=10))
        self.assertEqual(list(second["radar_state"]["items"]), [event_id])
        self.assertEqual(second["newly_eligible"], [])

    def test_news_index_remembers_expired_candidate_to_prevent_restart(self):
        rows=[make_row(name,suffix=str(i)) for i,name in enumerate(GENERAL[:3])]
        first=run(rows,at=BASE)
        event_id=next(iter(first["radar_state"]["items"]))
        expired=run([],previous=first["radar_state"],index=first["news_index"],
                    at=BASE+timedelta(hours=24))
        self.assertEqual(expired["news_index"]["items"][event_id]["status"],"archived")
        reappeared=run([make_row("EFE",suffix="other")],
                       previous=expired["radar_state"],index=expired["news_index"],
                       at=BASE+timedelta(hours=30))
        self.assertEqual(reappeared["newly_eligible"],[])
        self.assertNotIn("EFE",reappeared["radar_state"]["items"].get(event_id,{}).get("sources",[]))

    def test_nonmaterial_new_source_does_not_create_revision(self):
        old="El Supremo mantiene la suspensión del derecho a voto por la ley de nietos"
        index=ready_index(old)
        rows=[make_row("EFE",old,"new-source")]
        result=run(rows,index=index,at=BASE)
        self.assertEqual(result["material_updates_eligible"],[])
        self.assertEqual(result["news_index"]["items"]["ttn2-0123456789abcdef01234567"]["current_revision"],1)
        self.assertEqual(result["radar_state"]["material_updates"],{})

    def test_material_update_waits_for_four_new_independent_families_then_increments_revision(self):
        old="El Supremo mantiene la suspensión del derecho a voto por la ley de nietos"
        updated="El Supremo confirma la condena por la suspensión del derecho a voto de los nacionalizados por la ley de nietos"
        event_id="ttn2-0123456789abcdef01234567"
        index=ready_index(old,event_id,["Old Family A","Old Family B"])
        first=run([make_row("EFE",updated,"new-1")],index=index,at=BASE)
        self.assertEqual(first["material_updates_eligible"],[])
        self.assertEqual(first["news_index"]["items"][event_id]["current_revision"],1)
        rows=[make_row(name,updated,f"new-{i}") for i,name in enumerate(["EFE","Servimedia","elDiario.es","Público"])]
        second=run(rows,previous=first["radar_state"],index=first["news_index"],
                   at=BASE+timedelta(minutes=10))
        self.assertEqual(len(second["material_updates_eligible"]),1)
        event=second["material_updates_eligible"][0]
        self.assertEqual(event["event_id"],event_id)
        self.assertEqual(event["revision"],2)
        self.assertEqual(event["reason"],"material_update")
        item=second["news_index"]["items"][event_id]
        self.assertEqual(item["current_revision"],2)
        self.assertEqual(item["revision_refs"][-1]["reason"],"material_update")
        self.assertEqual(item["revision_refs"][-1]["editorial_job_id"],event_id+"-r2-editorial")

    def test_terminal_decision_blocks_automatic_reopening(self):
        old="El Supremo mantiene la suspensión del derecho a voto por la ley de nietos"
        updated="El Supremo confirma la condena por la suspensión del derecho a voto de los nacionalizados por la ley de nietos"
        index=ready_index(old)
        item=index["items"]["ttn2-0123456789abcdef01234567"]
        item["status"]="dismissed"
        item["terminal_status"]="dismissed"
        result=run([make_row("EFE",updated,"new")],index=index,at=BASE)
        self.assertEqual(result["material_updates_eligible"],[])
        self.assertEqual(result["radar_state"]["material_updates"],{})

    def test_material_update_from_existing_family_is_not_independent(self):
        old="El Supremo mantiene la suspensión del derecho a voto por la ley de nietos"
        updated="El Supremo confirma la condena por la suspensión del derecho a voto de los nacionalizados por la ley de nietos"
        index=ready_index(old,families=["EFE"])
        result=run([make_row("EFE",updated,"new")],index=index,at=BASE)
        self.assertEqual(result["material_updates_eligible"],[])
        self.assertEqual(result["radar_state"]["material_updates"],{})

    def test_source_health_counts_only_general_sources_and_reports_family_health(self):
        result=run([],source_statuses=statuses(),at=BASE)
        health=result["radar_state"]["source_health"]
        self.assertEqual(health["healthy_general_sources"],19)
        self.assertEqual(health["healthy_general_families"],16)
        self.assertFalse(health["health_degraded"])
        limited=statuses(GENERAL[:13])
        result=run([],source_statuses=limited,at=BASE)
        self.assertTrue(result["radar_state"]["source_health"]["health_degraded"])
        self.assertEqual(result["radar_state"]["source_health"]["healthy_general_sources"],13)

    def test_discovery_aggregator_timestamp_is_not_used_as_publisher_time(self):
        row=make_row("Reuters Radar","La noticia de ejemplo sobre un acontecimiento importante","r",
                     published_at="2026-11-16T09:55:00Z",publication_date_source="publisher_feed")
        result=run([row],at=BASE)
        accepted=result["accepted_rows"][0]
        self.assertIsNone(accepted["published_at"])
        self.assertIsNone(accepted["publication_date_source"])

    def test_pure_ingestion_does_not_mutate_input_documents(self):
        rows=[make_row(name,suffix=str(i)) for i,name in enumerate(GENERAL[:3])]
        prev={"schema_version":1,"project":"ttittulares-v2","items":{},"material_updates":{}}
        index={"schema_version":1,"project":"ttittulares-v2","items":{}}
        rows_before=copy.deepcopy(rows);prev_before=copy.deepcopy(prev);index_before=copy.deepcopy(index)
        run(rows,previous=prev,index=index,at=BASE)
        self.assertEqual(rows,rows_before)
        self.assertEqual(prev,prev_before)
        self.assertEqual(index,index_before)

    def test_scan_id_is_order_independent(self):
        rows=[make_row(name,suffix=str(i)) for i,name in enumerate(GENERAL[:4])]
        first=run(rows,at=BASE)
        second=run(list(reversed(rows)),at=BASE)
        self.assertEqual(first["radar_state"]["scan_id"],second["radar_state"]["scan_id"])
        self.assertEqual(first["newly_eligible"][0]["event_id"],second["newly_eligible"][0]["event_id"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
