import XCTest
@testable import TTActualidad

// Moved, not removed: this integration test requires the complete app target.
final class ApprovedImageAppIntegrationTests: XCTestCase {
    @MainActor
    func testManualImageAppearsImmediatelyOnlyOnExactTop30EditorialIdentity() {
        let editorialID = "e470cdee843b"
        let text = "Valverde, mismo episodio y texto editorial"
        let sha = String(repeating: "a", count: 64)
        let url = URL(string:
            "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/" +
            editorialID + "-r0-manual-aaaaaaaaaaaa.png")!
        var original = EditorialSnapshot()
        original.top30 = [
            TrendItem(id: "rank-2", rank: 2, name: "Valverde", explanation: text,
                lastExplained: nil, status: "EXPLICADA", inListas: false,
                editorialID: editorialID, revision: 0, imageURL: nil, sourceURL: nil,
                siteImageEditorialID: editorialID, siteImageRevision: 0),
            TrendItem(id: "rank-3", rank: 3, name: "Dumfries", explanation: text,
                lastExplained: nil, status: "EXPLICADA", inListas: false,
                editorialID: "unrelated", revision: 0, imageURL: nil, sourceURL: nil,
                siteImageEditorialID: "unrelated", siteImageRevision: 0)
        ]
        let changed = EditorialStore.withVerifiedManualImage(
            original, project: "ttendencias", editorialID: editorialID,
            revision: 0, editorialText: text, url: url, sha256: sha)
        XCTAssertEqual(changed.top30[0].siteImageURL, url)
        XCTAssertEqual(changed.top30[0].siteImageSHA256, sha)
        XCTAssertNil(changed.top30[1].siteImageURL)
        XCTAssertNil(original.top30[0].siteImageURL)
        let invalidURL = URL(string:
            "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/trends/generated-images/unrelated-r0-manual-aaaaaaaaaaaa.png")!
        let rejected = EditorialStore.withVerifiedManualImage(
            original, project: "ttendencias", editorialID: editorialID,
            revision: 0, editorialText: text, url: invalidURL, sha256: sha)
        XCTAssertNil(rejected.top30[0].siteImageURL)
    }

    // Regression: a slow Buffer/X publication must not re-enter Listas after
    // refreshing or reopening the iPhone. A different revision stays separate.
    @MainActor
    func testBufferReservationSurvivesTrackerRecreation() {
        let key = "test-" + UUID().uuidString
        let storage = "TTActualidad.bufferPendingHide.v2"
        let original = UserDefaults.standard.stringArray(forKey: storage) ?? []
        defer { UserDefaults.standard.set(original, forKey: storage) }

        let first = BufferPublishTracker()
        first.stagePublish(project: "ttendencias", id: key, revision: 1)
        XCTAssertTrue(first.hidesFromListas(project: "ttendencias", id: key, revision: 1))
        XCTAssertFalse(first.hidesFromListas(project: "ttendencias", id: key, revision: 2))
        let reopened = BufferPublishTracker()
        XCTAssertTrue(reopened.hidesFromListas(project: "ttendencias", id: key, revision: 1))
        XCTAssertFalse(reopened.alreadySent(project: "ttendencias", id: key, revision: 1))
    }

}
