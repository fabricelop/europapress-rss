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
}
