import XCTest

final class EditorialProgressPolicyTests: XCTestCase {
    func testNewsAlreadyAcceptedByGitHubContinuePollingWithoutPendingOrders() {
        XCTAssertTrue(EditorialProgressPolicy.shouldPoll(
            pendingOrders: 0, newsWorking: 8, trendsWorking: 0, viewingWorking: false))
    }

    func testTrendsAlreadyAcceptedAndOutstandingOrdersAlsoKeepPolling() {
        XCTAssertTrue(EditorialProgressPolicy.shouldPoll(
            pendingOrders: 0, newsWorking: 0, trendsWorking: 1, viewingWorking: false))
        XCTAssertTrue(EditorialProgressPolicy.shouldPoll(
            pendingOrders: 1, newsWorking: 0, trendsWorking: 0, viewingWorking: false))
    }

    func testOpenWorkingViewRefreshesEvenWhenItsLastReadWasEmpty() {
        XCTAssertTrue(EditorialProgressPolicy.shouldPoll(
            pendingOrders: 0, newsWorking: 0, trendsWorking: 0, viewingWorking: true))
        XCTAssertFalse(EditorialProgressPolicy.shouldPoll(
            pendingOrders: 0, newsWorking: 0, trendsWorking: 0, viewingWorking: false))
    }

    func testEmptyAuthoritativeQueueDoesNotResurrectStaleStatusRows() {
        let stale: [[String: Any]] = [["event_id": "already-finished", "revision": 1]]
        XCTAssertTrue(EditorialProgressPolicy.workingNewsRows(
            queue: [], fallback: stale, readyRevisions: [:]).isEmpty)
        XCTAssertEqual(EditorialProgressPolicy.workingNewsRows(
            queue: nil, fallback: stale, readyRevisions: [:]).count, 1)
    }

    func testReadyCardsAreNotSimultaneouslyDisplayedAsWorking() {
        let rows: [[String: Any]] = [
            ["event_id": "ready", "revision": 1],
            ["event_id": "ready", "revision": 2],
            ["event_id": "new", "revision": 1]]
        let pending = EditorialProgressPolicy.workingNewsRows(
            queue: rows, fallback: [], readyRevisions: ["ready": 1])
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.first?["revision"] as? Int, 2)
        XCTAssertEqual(pending.last?["event_id"] as? String, "new")
    }

    func testMissingReadyEntryAndNewRevisionsRemainPending() {
        XCTAssertTrue(EditorialProgressPolicy.isPending(queuedRevision: 1, readyRevision: nil))
        XCTAssertTrue(EditorialProgressPolicy.isPending(queuedRevision: 2, readyRevision: 1))
        XCTAssertFalse(EditorialProgressPolicy.isPending(queuedRevision: 1, readyRevision: 2))
    }

    func testReworkOverlayClosesOnlyAfterItsTargetReadyRevisionAppears() {
        XCTAssertFalse(EditorialProgressPolicy.finishedNewsAction(
            decision: "rework", originalRevision: 1, readyRevision: 1))
        XCTAssertTrue(EditorialProgressPolicy.finishedNewsAction(
            decision: "rework", originalRevision: 1, readyRevision: 2))
    }

    func testReadyCompletionDoesNotPretendToConfirmPublicationOrDeletion() {
        XCTAssertTrue(EditorialProgressPolicy.finishedNewsAction(
            decision: "prepare", originalRevision: 1, readyRevision: 1))
        for decision in ["deleted", "published", "discard"] {
            XCTAssertFalse(EditorialProgressPolicy.finishedNewsAction(
                decision: decision, originalRevision: 1, readyRevision: 2))
        }
        XCTAssertFalse(EditorialProgressPolicy.finishedNewsAction(
            decision: "prepare", originalRevision: 1, readyRevision: nil))
    }
}
