import XCTest

final class EditorialPendingPolicyTests: XCTestCase {
    func testOnlyOldUnverifiedAndInactiveCommandsCanBeArchived() {
        XCTAssertFalse(EditorialPendingPolicy.canArchive(
            age: 2 * 3600, receiptsFresh: true, queueFresh: true,
            decisionsFresh: true, hasReceipt: false, activeInQueue: false))
        XCTAssertTrue(EditorialPendingPolicy.canArchive(
            age: 7 * 3600, receiptsFresh: true, queueFresh: true,
            decisionsFresh: true, hasReceipt: false, activeInQueue: false))
        XCTAssertFalse(EditorialPendingPolicy.canArchive(
            age: 7 * 3600, receiptsFresh: false, queueFresh: true,
            decisionsFresh: true, hasReceipt: false, activeInQueue: false))
        XCTAssertFalse(EditorialPendingPolicy.canArchive(
            age: 7 * 3600, receiptsFresh: true, queueFresh: false,
            decisionsFresh: true, hasReceipt: false, activeInQueue: false))
        XCTAssertFalse(EditorialPendingPolicy.canArchive(
            age: 7 * 3600, receiptsFresh: true, queueFresh: true,
            decisionsFresh: false, hasReceipt: false, activeInQueue: false))
        XCTAssertFalse(EditorialPendingPolicy.canArchive(
            age: 7 * 3600, receiptsFresh: true, queueFresh: true,
            decisionsFresh: true, hasReceipt: true, activeInQueue: false))
        XCTAssertFalse(EditorialPendingPolicy.canArchive(
            age: 7 * 3600, receiptsFresh: true, queueFresh: true,
            decisionsFresh: true, hasReceipt: false, activeInQueue: true))
    }
    func testUnknownIdentityRequiresLongerAuditWindow() {
        XCTAssertEqual(EditorialPendingPolicy.archivalAge, 6 * 3600)
        XCTAssertEqual(EditorialPendingPolicy.unidentifiedAge, 24 * 3600)
    }
}


final class TrendPendingRemovalPolicyTests: XCTestCase {
    private let oldEntry = Date(timeIntervalSince1970: 1_794_602_000)
    private let retirement = Date(timeIntervalSince1970: 1_794_603_000)
    private let newEntry = Date(timeIntervalSince1970: 1_794_604_000)

    private var records: [TrendPendingRetirement] {
        [TrendPendingRetirement(editorialID: "1ea1a6c850b1",
                                revision: 3, name: "españas",
                                retiredAt: retirement)]
    }

    func testOldEspanasNoLongerAppearsInPendientes() {
        XCTAssertFalse(TrendPendingRemovalPolicy.isVisible(
            id: "1ea1a6c850b1", revision: 3,
            name: "ESPAÑAS", enteredAt: oldEntry, retirements: records))
        XCTAssertFalse(TrendPendingRemovalPolicy.isVisible(
            id: "1ea1a6c850b1", revision: 3,
            name: "españas", enteredAt: nil, retirements: records))
        XCTAssertFalse(TrendPendingRemovalPolicy.isVisible(
            id: "unexplained-1ea1a6c850b1", revision: 3,
            name: "Españas", enteredAt: nil, retirements: records))
    }

    func testNewTop30EntryCanReturnWithoutTermBlacklist() {
        XCTAssertTrue(TrendPendingRemovalPolicy.isVisible(
            id: "new-episode", revision: 0,
            name: "españas", enteredAt: newEntry, retirements: records))
        XCTAssertTrue(TrendPendingRemovalPolicy.isVisible(
            id: "other", revision: 0,
            name: "Colau", enteredAt: nil, retirements: records))
        XCTAssertTrue(TrendPendingRemovalPolicy.isVisible(
            id: "1ea1a6c850b1", revision: 4,
            name: "españas", enteredAt: newEntry, retirements: records))
    }

    func testLaterScanOrRankChangeDoesNotReopenOldEpisode() {
        XCTAssertFalse(TrendPendingRemovalPolicy.isVisible(
            id: "new-id-without-proven-entry", revision: 0,
            name: "españas", enteredAt: nil, retirements: records))
        XCTAssertTrue(TrendPendingRemovalPolicy.isVisible(
            id: "1ea1a6c850b1", revision: 3,
            name: "españas", enteredAt: oldEntry, retirements: []))
    }
}
