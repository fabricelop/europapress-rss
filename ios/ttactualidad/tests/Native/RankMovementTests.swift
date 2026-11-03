import XCTest
final class RankMovementTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1793707200)
    func entry(_ overrides: [String: Any] = [:]) -> [String: Any] {
        ["name":"Primera", "rank":3, "movement_version":3, "movement":"new", "entered_top30_at":"2026-11-03T11:45:00Z"].merging(overrides,uniquingKeysWith: {_,new in new})
    }
    func testOnlyTrustedFirstEntryIsNew() {
        XCTAssertEqual(RankMovement.newNames([entry()],now:now),Set(["Primera"]))
        XCTAssertTrue(RankMovement.newNames([entry(["movement_version":2])],now:now).isEmpty)
        XCTAssertTrue(RankMovement.newNames([entry(["movement":"up"])],now:now).isEmpty)
    }
    func testNewWindowExpiresAndNeverAcceptsFutureOrMissingClock() {
        XCTAssertTrue(RankMovement.newNames([entry(["entered_top30_at":"2026-11-03T10:00:00Z"])],now:now).isEmpty)
        XCTAssertTrue(RankMovement.newNames([entry(["entered_top30_at":"2026-11-03T14:00:00Z"])],now:now).isEmpty)
        XCTAssertTrue(RankMovement.newNames([entry(["entered_top30_at":"invalid"])],now:now).isEmpty)
    }
    func testReturningKnownTopicAndInvalidRankCannotBeNew() {
        XCTAssertTrue(RankMovement.newNames([entry(["movement":"flat"]),entry(["rank":31])],now:now).isEmpty)
    }
}
