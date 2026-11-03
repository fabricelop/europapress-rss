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
