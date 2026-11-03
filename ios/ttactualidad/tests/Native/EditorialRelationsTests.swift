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
