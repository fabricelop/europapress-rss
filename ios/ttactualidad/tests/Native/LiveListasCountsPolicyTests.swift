import Foundation
import XCTest

final class LiveListasCountsPolicyTests: XCTestCase {
    func testBufferReservationsAndSentHideExactRevisionsOnly() {
        let rows: [[String: Any]] = [
            ["project": "ttittulares", "event_id": "n1", "revision": 1, "state": "pending"],
            ["project": "ttendencias", "event_id": "t2", "revision": 2, "state": "sent"],
            ["project": "ttittulares", "event_id": "n3", "revision": 1, "state": "reserved"],
            ["project": "ttittulares", "event_id": "n4", "revision": 1, "state": "unknown"],
            ["project": "ttittulares", "event_id": "n5", "revision": 1, "state": "failed"],
            ["project": "ttittulares", "event_id": "n6", "revision": 1, "state": "cancelled"]
        ]
        let hidden = LiveListasCountsPolicy.hiddenKeys(bufferRows: rows)
        XCTAssertEqual(hidden.count, 4)
        XCTAssertFalse(LiveListasCountsPolicy.visible(
            project: "ttittulares", id: "n1", revision: 1, hidden: hidden))
        XCTAssertTrue(LiveListasCountsPolicy.visible(
            project: "ttittulares", id: "n1", revision: 2, hidden: hidden))
        XCTAssertFalse(LiveListasCountsPolicy.visible(
            project: "ttendencias", id: "t2", revision: 2, hidden: hidden))
        XCTAssertTrue(LiveListasCountsPolicy.visible(
            project: "ttittulares", id: "n5", revision: 1, hidden: hidden))
    }

    func testInvalidUnknownOrIncompleteRecordsNeverHideNews() {
        let hidden = LiveListasCountsPolicy.hiddenKeys(bufferRows: [
            ["project": "ttittulares", "event_id": "", "revision": 1, "state": "sent"],
            ["project": "bad", "event_id": "n1", "revision": 1, "state": "sent"],
            ["project": "ttittulares", "event_id": "n2", "state": "sent"],
            ["project": "ttittulares", "event_id": "n3", "revision": -1, "state": "sent"],
            ["project": "ttittulares", "event_id": "n4", "revision": 0, "state": "sent"]
        ])
        XCTAssertEqual(hidden, Set(["ttittulares:n4:r0"]))
        XCTAssertTrue(LiveListasCountsPolicy.visible(
            project: "ttittulares", id: "n4", revision: 1, hidden: hidden))
    }
}
