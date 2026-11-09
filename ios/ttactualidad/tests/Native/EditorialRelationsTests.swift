import XCTest

final class EditorialRelationsTests: XCTestCase {
    func testStableEpisodeIdentitySeparatesRevisionsAndDuplicates() {
        let first = EditorialRelationEndpoint(id: "same-news", revision: 1,
            episodeFingerprint: "episode-A", title: "Same title", text: "", path: nil)
        let duplicate = EditorialRelationEndpoint(id: "same-news", revision: 1,
            episodeFingerprint: "episode-A", title: "Changed title", text: "", path: nil)
        let differentRevision = EditorialRelationEndpoint(id: "same-news", revision: 2,
            episodeFingerprint: "episode-A", title: "Same title", text: "", path: nil)
        let differentEpisode = EditorialRelationEndpoint(id: "same-news", revision: 1,
            episodeFingerprint: "episode-B", title: "Same title", text: "", path: nil)
        XCTAssertEqual(first.stableIdentity, duplicate.stableIdentity)
        XCTAssertNotEqual(first.stableIdentity, differentRevision.stableIdentity)
        XCTAssertNotEqual(first.stableIdentity, differentEpisode.stableIdentity)
    }

    func testStrictEndpointIdentityDoesNotUseRankOrTitle() throws {
        let endpoint = EditorialRelationEndpoint(id: "trend-one", revision: 3,
            episodeFingerprint: "episode-current", title: "Andorra", text: "One episode", path: nil)
        XCTAssertTrue(EditorialRelationsPolicy.matches(endpoint, id: "trend-one", revision: 3))
        XCTAssertFalse(EditorialRelationsPolicy.matches(endpoint, id: "trend-one", revision: 2))
        XCTAssertFalse(EditorialRelationsPolicy.matches(endpoint, id: "Andorra", revision: 3))
        let data = try JSONEncoder().encode(EditorialRelationDecision(action: "link",
            expectedNews: EditorialRelationIdentity(id: "news-one", revision: 1, episodeFingerprint: "news-episode"),
            expectedTrend: endpoint.identity, commandId: "stable-command"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = try XCTUnwrap(object["expectedTrend"] as? [String: Any])
        XCTAssertEqual(expected["episodeFingerprint"] as? String, "episode-current")
        XCTAssertEqual(object["commandId"] as? String, "stable-command")
        XCTAssertNil(object["rank"])
    }

    func testCanonicalRelationDoesNotSuggestAlreadyLinkedPairAgain() throws {
        let payload = #"""
        {"items":[
          {"id":"suggestion","news":{"id":"n1","revision":2,"episodeFingerprint":"N","title":"Noticia","text":"Hechos"},"trend":{"id":"t1","revision":0,"episodeFingerprint":"T","title":"Tema","text":"Explicación"},"state":"suggested","origin":"automatic","reason":"Similar"},
          {"id":"link","news":{"id":"n1","revision":2,"episodeFingerprint":"N","title":"Noticia","text":"Hechos"},"trend":{"id":"t1","revision":0,"episodeFingerprint":"T","title":"Tema","text":"Explicación"},"state":"linked","origin":"manual","reason":"Aprobada"},
          {"id":"other-episode","news":{"id":"n1","revision":2,"episodeFingerprint":"N2","title":"Noticia","text":"Otros hechos"},"trend":{"id":"t1","revision":0,"episodeFingerprint":"T","title":"Tema","text":"Explicación"},"state":"suggested","origin":"automatic","reason":"Otro caso"}
        ],"news":[],"trends":[]}
        """#
        let snapshot = try JSONDecoder().decode(EditorialRelationsSnapshot.self,
                                               from: Data(payload.utf8))
        let canonical = EditorialRelationsPolicy.canonical(snapshot.items)
        XCTAssertEqual(canonical.count, 2)
        XCTAssertEqual(canonical[0].state, "linked")
        XCTAssertEqual(canonical[0].origin, "manual")
        XCTAssertEqual(canonical[1].state, "suggested")
        XCTAssertEqual(canonical[1].news.episodeFingerprint, "N2")
    }

    func testManualBlockPreventsDuplicateAutomaticRelink() throws {
        let payload = #"""
        {"items":[
          {"id":"auto","news":{"id":"n1","revision":1,"episodeFingerprint":"N","title":"Noticia","text":""},"trend":{"id":"t1","revision":0,"episodeFingerprint":"T","title":"Tendencia","text":""},"state":"linked","origin":"automatic","reason":""},
          {"id":"veto","news":{"id":"n1","revision":1,"episodeFingerprint":"N","title":"Noticia","text":""},"trend":{"id":"t1","revision":0,"episodeFingerprint":"T","title":"Tendencia","text":""},"state":"blocked","origin":"manual","reason":""}
        ],"news":[],"trends":[]}
        """#
        let snapshot = try JSONDecoder().decode(EditorialRelationsSnapshot.self,
                                               from: Data(payload.utf8))
        let canonical = EditorialRelationsPolicy.canonical(snapshot.items)
        XCTAssertEqual(canonical.count, 1)
        XCTAssertEqual(canonical[0].state, "blocked")
        XCTAssertEqual(canonical[0].id, "veto")
    }

    func testOnlyListasNewsAppearInPrimaryRelationInbox() {
        let inListas = EditorialRelationEndpoint(
            id: "ready", revision: 1, episodeFingerprint: "A",
            title: "Noticia reciente", text: "", path: nil)
        let former = EditorialRelationEndpoint(
            id: "former", revision: 2, episodeFingerprint: "B",
            title: "Noticia retirada", text: "", path: nil)
        let keys: Set<String> = ["ready:r1"]
        XCTAssertTrue(EditorialRelationsPolicy.isVisibleNews(
            inListas, activeListas: keys, explicit: nil))
        XCTAssertFalse(EditorialRelationsPolicy.isVisibleNews(
            former, activeListas: keys, explicit: nil))
        XCTAssertTrue(EditorialRelationsPolicy.isVisibleNews(
            former, activeListas: keys, explicit: former))
        XCTAssertFalse(EditorialRelationsPolicy.isVisibleNews(
            EditorialRelationEndpoint(
                id: "ready", revision: 0, episodeFingerprint: "older",
                title: "Vieja revisión", text: "", path: nil),
            activeListas: keys, explicit: nil))
    }

    func testOptionalListingDateAndIdentityStayIndependent() throws {
        let withoutDate = try JSONDecoder().decode(EditorialRelationEndpoint.self,
            from: Data(#"{"id":"n","revision":1,"episodeFingerprint":"E","title":"N","text":""}"#.utf8))
        XCTAssertNil(withoutDate.listedAt)
        let withDate = try JSONDecoder().decode(EditorialRelationEndpoint.self,
            from: Data(#"{"id":"n","revision":1,"episodeFingerprint":"E","title":"N","text":"","listedAt":"2026-11-04T10:00:00Z"}"#.utf8))
        XCTAssertEqual(withDate.listedAt, "2026-11-04T10:00:00Z")
        XCTAssertEqual(withDate.stableIdentity, withoutDate.stableIdentity)
    }

    func testRecentNewsIncludesRemovedListasEpisodesAndStrict12HourWindow() {
        let now = EditorialRelationsPolicy.parsedDate("2026-11-05T09:00:00Z")!
        let recentRemoved = EditorialRelationEndpoint(
            id: "removed", revision: 2, episodeFingerprint: "N1",
            title: "Publicada y fuera de Listas", text: "Hechos", path: nil,
            listedAt: "2026-11-05T02:00:00Z")
        let older = EditorialRelationEndpoint(
            id: "old", revision: 1, episodeFingerprint: "N2",
            title: "Más de 12 horas", text: "Hechos", path: nil,
            listedAt: "2026-11-04T17:00:00Z")
        let withoutDate = EditorialRelationEndpoint(
            id: "undated", revision: 1, episodeFingerprint: "N3",
            title: "Fecha ausente", text: "Hechos", path: nil)
        let candidates = [older, recentRemoved, recentRemoved, withoutDate]
        XCTAssertEqual(EditorialRelationsPolicy.recentNews(candidates, hours: 12, now: now)
            .map(\.id), ["removed"])
        XCTAssertEqual(EditorialRelationsPolicy.recentNews(candidates, hours: 24, now: now)
            .map(\.id), ["removed", "old"])
        XCTAssertEqual(EditorialRelationsPolicy.recentNews(
            candidates, hours: 12, now: now,
            hidden: [recentRemoved.stableIdentity]).count, 0)
        // Never invent a timestamp for a historical episode.
        XCTAssertNil(EditorialRelationsPolicy.parsedDate(withoutDate.listedAt))
        let fallback = [EditorialRelationsPolicy.newsKey(id: "undated", revision: 1):
            EditorialRelationsPolicy.parsedDate("2026-11-05T08:30:00Z")!]
        XCTAssertEqual(EditorialRelationsPolicy.recentNews(
            candidates, hours: 12, now: now, fallbackDates: fallback)
            .map(\.id), ["undated", "removed"])
    }

    func testRecentInboxShowsGitHubOnlyNewsWhenSitesReturnsNoNews() {
        let now = EditorialRelationsPolicy.parsedDate("2026-11-05T08:05:00Z")!
        // Historical news remains selectable by its exact stable ID/revision
        // when the private snapshot omits an opaque episode fingerprint.
        // The server must still verify identity and return an actual receipt.
        let savedHistory = EditorialRelationEndpoint(
            id: "c1e7f17edda4", revision: 1, episodeFingerprint: "",
            title: "La Séptima arranca mañana como nuevo canal generalista de la TDT",
            text: "", path: nil, listedAt: "2026-11-05T07:36:30Z")
        let recent = EditorialRelationsPolicy.recentNews(
            [savedHistory], hours: 12, now: now)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, "c1e7f17edda4")
        XCTAssertTrue(recent.first?.episodeFingerprint.isEmpty == true)
        XCTAssertEqual(EditorialRelationsPolicy.recentNews(
            [savedHistory], hours: 12, now: now,
            hidden: ["c1e7f17edda4:r1"]).count, 0)
        XCTAssertTrue(EditorialRelationsPolicy.matches(savedHistory,
            id: "c1e7f17edda4", revision: 1))
        XCTAssertNil(savedHistory.identity.episodeFingerprint)
        XCTAssertFalse(EditorialRelationsPolicy.matches(savedHistory,
            id: "c1e7f17edda4", revision: 2))
    }

    func testTimestampParsingSupportsFractionalSecondsAndTimezones() {
        XCTAssertNotNil(EditorialRelationsPolicy.parsedDate("2026-11-05T07:45:15.123Z"))
        XCTAssertNotNil(EditorialRelationsPolicy.parsedDate("2026-11-05T08:45:15+01:00"))
        XCTAssertNil(EditorialRelationsPolicy.parsedDate("yesterday"))
    }

    func testSwitchChangesOnlyChangedPairsNotAutomaticSuggestions() {
        XCTAssertNil(EditorialRelationsPolicy.actionForSwitch(current: "suggested", selected: false))
        XCTAssertNil(EditorialRelationsPolicy.actionForSwitch(current: "blocked", selected: false))
        XCTAssertNil(EditorialRelationsPolicy.actionForSwitch(current: "linked", selected: true))
        XCTAssertEqual(EditorialRelationsPolicy.actionForSwitch(current: "suggested", selected: true), "link")
        XCTAssertEqual(EditorialRelationsPolicy.actionForSwitch(current: "blocked", selected: true), "link")
        XCTAssertEqual(EditorialRelationsPolicy.actionForSwitch(current: "linked", selected: false), "unlink")
    }

    func testTop30EpisodeMatchingCanUseExactFingerprintWithoutTextEquality() {
        let confirmed = EditorialRelationEndpoint(
            id: "trend-123", revision: 2, episodeFingerprint: "site-signed-episode",
            title: "Top 30 trend", text: "Texto original de tendencia",
            path: nil)
        let different = EditorialRelationEndpoint(
            id: "trend-123", revision: 2, episodeFingerprint: "other-episode",
            title: "Top 30 trend", text: "Otra revisión sin subir número",
            path: nil)
        XCTAssertEqual(EditorialRelationsPolicy.matchingTop30Endpoint(
            id: "trend-123", revision: 2, renderedText: "TT#1 Texto visible diferente",
            candidates: [confirmed])?.episodeFingerprint, "site-signed-episode")
        XCTAssertNil(EditorialRelationsPolicy.matchingTop30Endpoint(
            id: "trend-123", revision: 2, renderedText: "TT#1 Texto visible diferente",
            candidates: [confirmed, different]))
        XCTAssertEqual(EditorialRelationsPolicy.matchingTop30Endpoint(
            id: "trend-123", revision: 2, renderedText: different.text,
            candidates: [confirmed, different])?.episodeFingerprint, "other-episode")
        XCTAssertNil(EditorialRelationsPolicy.matchingTop30Endpoint(
            id: "", revision: 0, renderedText: "", candidates: [confirmed]))
    }

    func testTrendSearchMatchesNewsBodyOrTitleNotSubstrings() {
        let bodyMatch = EditorialRelationEndpoint(
            id: "a", revision: 1, episodeFingerprint: "",
            title: "Balance político", text: "TRUMP se reúne en la Casa Blanca",
            path: nil, listedAt: "2026-11-06T09:00:00Z")
        let titleMatch = EditorialRelationEndpoint(
            id: "b", revision: 1, episodeFingerprint: "",
            title: "Ábalos declara ante el juez", text: "",
            path: nil, listedAt: "2026-11-06T08:00:00Z")
        let substring = EditorialRelationEndpoint(
            id: "c", revision: 1, episodeFingerprint: "",
            title: "Comparación de instrumentos", text: "una trompeta",
            path: nil, listedAt: "2026-11-06T07:00:00Z")
        XCTAssertTrue(EditorialRelationsPolicy.newsMentionsTrend(bodyMatch, name: "Trump"))
        XCTAssertTrue(EditorialRelationsPolicy.newsMentionsTrend(titleMatch, name: "abalos"))
        XCTAssertFalse(EditorialRelationsPolicy.newsMentionsTrend(substring, name: "Trump"))
        XCTAssertFalse(EditorialRelationsPolicy.newsMentionsTrend(bodyMatch, name: "   "))
        XCTAssertFalse(EditorialRelationsPolicy.newsMentionsTrend(bodyMatch, name: "Putin"))
    }

    func testTrendSearchUsesAllHistoricalNewsWithoutDateOrHiddenBlocks() {
        let now = EditorialRelationsPolicy.parsedDate("2026-11-06T12:00:00Z")!
        func make(_ id: String, _ revision: Int, _ when: String?,
                  _ text: String = "Trump anuncia cambios") -> EditorialRelationEndpoint {
            EditorialRelationEndpoint(
                id: id, revision: revision, episodeFingerprint: "",
                title: "Noticia " + id, text: text, path: nil, listedAt: when)
        }
        let recent = (0..<7).map {
            make("n" + String($0), 1,
                 String(format: "2026-11-06T%02d:00:00Z", 11 - $0))
        }
        let old = make("old", 1, "2026-10-30T11:59:59Z")
        let edge = make("edge", 1, "2026-10-30T12:00:00Z")
        let future = make("future", 1, "2026-11-07T12:00:00Z")
        let undated = make("undated", 1, nil)
        let unrelated = make("unrelated", 1, "2026-11-06T11:30:00Z", "Economía y deporte")
        let candidates = [old, edge, future, undated, unrelated] +
            recent + [recent[0], make("n0", 2, "2026-11-06T10:30:00Z")]
        let found = EditorialRelationsPolicy.newsForTrend(
            candidates, name: "Trump", now: now)
        XCTAssertEqual(found.map(\.id), ["future", "n0", "n1", "n2", "n3"])
        XCTAssertEqual(found.count, 5)
        XCTAssertEqual(EditorialRelationsPolicy.newsForTrend(
            [edge, old, undated, unrelated], name: "Trump", now: now).map(\.id),
            ["edge", "old", "undated"])
        XCTAssertEqual(EditorialRelationsPolicy.newsForTrend(
            candidates, name: "Trump", now: now, hidden: ["n0:r1"]).map(\.id),
            ["future", "n0", "n1", "n2", "n3"])
        XCTAssertEqual(EditorialRelationsPolicy.newsForTrend(
            [recent[0]], name: "Trump", now: now,
            hidden: [recent[0].stableIdentity]).count, 1)
        XCTAssertEqual(EditorialRelationsPolicy.newsForTrend(
            candidates, name: "Trump", now: now, limit: 2).count, 2)
    }

    func testOnlyConfirmedDecisionCountsAsSaved() {
        XCTAssertTrue(EditorialRelationsPolicy.confirms(.init(state: "linked", relationId: "r"), action: "link"))
        XCTAssertTrue(EditorialRelationsPolicy.confirms(.init(state: "blocked", relationId: "r"), action: "unlink"))
        XCTAssertTrue(EditorialRelationsPolicy.confirms(.init(state: "blocked", relationId: "r"), action: "dismiss"))
        XCTAssertFalse(EditorialRelationsPolicy.confirms(.init(state: "suggested", relationId: "r"), action: "link"))
        XCTAssertFalse(EditorialRelationsPolicy.confirms(.init(state: "linked", relationId: ""), action: "link"))
        XCTAssertFalse(EditorialRelationsPolicy.confirms(.init(state: "linked", relationId: "r"), action: "unlink"))
    }

    func testSnapshotRetainsBlockedManualDecisionAndOpaqueEpisode() throws {
        let json = #"{"items":[{"id":"r","news":{"id":"n","revision":1,"episodeFingerprint":"news-episode","title":"News","text":"Facts"},"trend":{"id":"t","revision":0,"episodeFingerprint":"trend-episode","title":"Trend","text":"Explanation"},"state":"blocked","origin":"manual","reason":"Different episode"}],"news":[],"trends":[]}"#
        let snapshot = try JSONDecoder().decode(EditorialRelationsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.items.first?.state, "blocked")
        XCTAssertEqual(snapshot.items.first?.origin, "manual")
        XCTAssertEqual(snapshot.items.first?.trend.episodeFingerprint, "trend-episode")
        XCTAssertNil(snapshot.items.first?.trend.path)
    }
    func testPerTrendLookupHasNoExtraDateOrListasFilter() {
        let publishedOld = EditorialRelationEndpoint(
            id: "published-old", revision: 2, episodeFingerprint: "",
            title: "Carrera histórica en Interlagos", text: "",
            path: nil, listedAt: "2021-11-01T08:00:00Z")
        let undated = EditorialRelationEndpoint(
            id: "radar-unlisted", revision: 0, episodeFingerprint: "",
            title: "Noticia sin fecha", text: "Fernando Alonso menciona #Interlagos",
            path: nil)
        let unrelated = EditorialRelationEndpoint(
            id: "unrelated", revision: 0, episodeFingerprint: "",
            title: "Otra carrera", text: "No hay datos de esa pista",
            path: nil)
        let found = EditorialRelationsPolicy.newsForTrend(
            [unrelated, undated, publishedOld], name: "#Interlagos",
            now: EditorialRelationsPolicy.parsedDate("2026-11-08T00:20:00Z")!,
            hidden: [publishedOld.stableIdentity], limit: 5)
        XCTAssertEqual(found.map(\.id), ["published-old", "radar-unlisted"])
        XCTAssertEqual(EditorialRelationsPolicy.newsForTrend(
            [publishedOld, undated], name: "#Interlagos", limit: 1).count, 1)
    }


    func testJulianAllowsSavingDisplayedHistoricalNewsWithoutExtraFingerprint() throws {
        let news = EditorialRelationEndpoint(
            id: "e1f64f5801b7", revision: 1, episodeFingerprint: "",
            title: "Julián participa en el Atlético-Barça", text: "Julián dio una asistencia",
            path: nil)
        let trend = EditorialRelationEndpoint(
            id: "trend-update-08da896cbbe389cf5192", revision: 0,
            episodeFingerprint: "", title: "Julián", text: "Atlético-Barça",
            path: nil)
        XCTAssertTrue(EditorialRelationsPolicy.newsMentionsTrend(news, name: "Julián"))
        XCTAssertEqual(EditorialRelationsPolicy.actionForSwitch(
            current: nil, selected: true), "link")
        let decision = EditorialRelationDecision(
            action: "link", expectedNews: news.identity, expectedTrend: trend.identity,
            commandId: "julian-manual-link-0001")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decision))
            as? [String: Any]
        let expectedNews = body?["expectedNews"] as? [String: Any]
        XCTAssertEqual(expectedNews?["id"] as? String, news.id)
        XCTAssertEqual(expectedNews?["revision"] as? Int, 1)
        XCTAssertNil(expectedNews?["episodeFingerprint"])
        XCTAssertEqual(EditorialRelationsPolicy.pairKey(news, trend),
            "e1f64f5801b7:r1↔trend-update-08da896cbbe389cf5192:r0")
    }

    func testReadbackRequiresActualWebRelationNotJustAcceptedPost() throws {
        let snapshot = try JSONDecoder().decode(EditorialRelationsSnapshot.self,
            from: Data(#"""
            {"items":[{
                "id":"linked-julian",
                "news":{"id":"news-julian","revision":2,"episodeFingerprint":"server-news","title":"Julián en el campo","text":""},
                "trend":{"id":"trend-julian","revision":0,"episodeFingerprint":"server-trend","title":"Julián","text":""},
                "state":"linked","origin":"manual","reason":"Editor"}
            ],"news":[],"trends":[]}
            """#.utf8))
        let linked = try XCTUnwrap(snapshot.items.first)
        let localNews = EditorialRelationEndpoint(
            id:"news-julian",revision:2,episodeFingerprint:"",
            title:"Julián en el campo",text:"",path:nil)
        let localTrend = EditorialRelationEndpoint(
            id:"trend-julian",revision:0,episodeFingerprint:"",
            title:"Julián",text:"",path:nil)
        XCTAssertTrue(EditorialRelationsPolicy.persisted(snapshot.items,
            news:localNews,trend:localTrend,action:"link"))
        XCTAssertFalse(EditorialRelationsPolicy.persisted([],
            news:localNews,trend:localTrend,action:"link"))
        XCTAssertFalse(EditorialRelationsPolicy.persisted(snapshot.items,
            news:localNews,trend:localTrend,action:"unlink"))
        let wrongRevision = EditorialRelationEndpoint(
            id:localNews.id,revision:3,episodeFingerprint:"",
            title:localNews.title,text:"",path:nil)
        XCTAssertFalse(EditorialRelationsPolicy.persisted(snapshot.items,
            news:wrongRevision,trend:localTrend,action:"link"))
        let wrongFingerprint = EditorialRelationEndpoint(
            id:linked.news.id,revision:linked.news.revision,
            episodeFingerprint:"stale-or-untrusted",title:linked.news.title,
            text:"",path:nil)
        XCTAssertFalse(EditorialRelationsPolicy.persisted(snapshot.items,
            news:wrongFingerprint,trend:localTrend,action:"link"))
        XCTAssertEqual(EditorialRelationsPolicy.pairKey(localNews,localTrend),
            EditorialRelationsPolicy.pairKey(linked.news,linked.trend))
    }

    func testUnlinkAppearsOnlyAfterServerReadback() throws {
        let blocked = try JSONDecoder().decode(EditorialRelationsSnapshot.self,
            from: Data(#"""
            {"items":[{
                "id":"blocked-julian",
                "news":{"id":"news-julian","revision":1,"episodeFingerprint":"N","title":"Noticia","text":""},
                "trend":{"id":"trend-julian","revision":0,"episodeFingerprint":"T","title":"Julián","text":""},
                "state":"blocked","origin":"manual","reason":"Editor"}
            ],"news":[],"trends":[]}
            """#.utf8))
        let item = try XCTUnwrap(blocked.items.first)
        XCTAssertTrue(EditorialRelationsPolicy.persisted(blocked.items,
            news:item.news,trend:item.trend,action:"unlink"))
        XCTAssertFalse(EditorialRelationsPolicy.persisted(blocked.items,
            news:item.news,trend:item.trend,action:"link"))
    }

    func testJulianManualLinksOverrideSuggestionsAndCountAllLinkedNews() throws {
        // Site v85 may return a suggestion and a confirmed link with different
        // fingerprints for the same pair. Ordering must not clear the check.
        let data = Data(#"""
        {"items":[
          {"id":"cerezo-manual","news":{"id":"9ed95352b91b","revision":1,"episodeFingerprint":"N1","title":"Enrique Cerezo sobre Julián","text":""},"trend":{"id":"trend-update-08da896cbbe389cf5192","revision":0,"episodeFingerprint":"T1","title":"Julián","text":""},"state":"linked","origin":"manual","reason":"editor"},
          {"id":"cerezo-auto","news":{"id":"9ed95352b91b","revision":1,"episodeFingerprint":"","title":"Enrique Cerezo sobre Julián","text":""},"trend":{"id":"trend-update-08da896cbbe389cf5192","revision":0,"episodeFingerprint":"","title":"Julián","text":""},"state":"suggested","origin":"automatic","reason":"match"},
          {"id":"simeone-manual","news":{"id":"9593c2b869f1","revision":1,"episodeFingerprint":"N2","title":"Simeone: lo necesitamos","text":""},"trend":{"id":"trend-update-08da896cbbe389cf5192","revision":0,"episodeFingerprint":"T1","title":"Julián","text":""},"state":"linked","origin":"manual","reason":"editor"},
          {"id":"nadal-manual","news":{"id":"some-other-news","revision":1,"episodeFingerprint":"N3","title":"Nadal","text":""},"trend":{"id":"another-trend","revision":0,"episodeFingerprint":"T3","title":"Nadal","text":""},"state":"linked","origin":"manual","reason":"editor"}
        ],"news":[],"trends":[]}
        """#.utf8)
        let snap = try JSONDecoder().decode(EditorialRelationsSnapshot.self, from: data)
        let first = try XCTUnwrap(snap.items.first)
        let states = EditorialRelationsPolicy.effectivePairStates(snap.items)
        XCTAssertEqual(states[EditorialRelationsPolicy.pairKey(first.news, first.trend)], "linked")
        XCTAssertEqual(
            EditorialRelationsPolicy.confirmedCount(
                snap.items,
                trendID: "trend-update-08da896cbbe389cf5192", revision: 0),
            2)
        XCTAssertEqual(
            EditorialRelationsPolicy.confirmedCount(
                snap.items,
                trendID: "trend-update-08da896cbbe389cf5192", revision: 1),
            0)
        XCTAssertNil(EditorialRelationsPolicy.actionForSwitch(
            current: states[EditorialRelationsPolicy.pairKey(first.news, first.trend)],
            selected: true))
    }

    func testManualUnlinkWinsOverEarlierLinkedRecordAtExactPair() throws {
        let data = Data(#"""
        {"items":[
          {"id":"link","news":{"id":"9ed95352b91b","revision":1,"episodeFingerprint":"old","title":"Cerezo","text":""},"trend":{"id":"julian","revision":0,"episodeFingerprint":"old","title":"Julián","text":""},"state":"linked","origin":"automatic","reason":""},
          {"id":"unlink","news":{"id":"9ed95352b91b","revision":1,"episodeFingerprint":"new","title":"Cerezo","text":""},"trend":{"id":"julian","revision":0,"episodeFingerprint":"new","title":"Julián","text":""},"state":"blocked","origin":"manual","reason":"Editor"}
        ],"news":[],"trends":[]}
        """#.utf8)
        let snap = try JSONDecoder().decode(EditorialRelationsSnapshot.self, from: data)
        XCTAssertEqual(EditorialRelationsPolicy.confirmedCount(
            snap.items, trendID: "julian", revision: 0), 0)
    }
}
