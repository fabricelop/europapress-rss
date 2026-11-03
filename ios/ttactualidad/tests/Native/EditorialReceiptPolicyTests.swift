import XCTest

final class EditorialReceiptPolicyTests: XCTestCase {
    private let exact: [String: Any] = [
        "request_id": "request-123", "project": "ttendencias",
        "event_id": "trend-1", "revision": 4,
        "decision": "rework", "status": "applied"
    ]

    func testExactAppliedReworkReconcilesToWorking() {
        XCTAssertEqual(EditorialReceiptPolicy.resolution(
            project: "ttendencias", eventID: "trend-1", revision: 4,
            decision: "rework", requestID: "request-123", receipt: exact),
            "En elaboración")
    }

    func testUnrelatedReceiptNeverConfirmsAnotherRequestOrEpisode() {
        for requestID in ["other-request", ""] {
            XCTAssertNil(EditorialReceiptPolicy.resolution(
                project: "ttendencias", eventID: "trend-1", revision: 4,
                decision: "rework", requestID: requestID, receipt: exact))
        }
        XCTAssertNil(EditorialReceiptPolicy.resolution(
            project: "ttendencias", eventID: "trend-1", revision: 5,
            decision: "rework", requestID: "request-123", receipt: exact))
        XCTAssertNil(EditorialReceiptPolicy.resolution(
            project: "ttittulares", eventID: "trend-1", revision: 4,
            decision: "rework", requestID: "request-123", receipt: exact))
    }

    func testRejectedIsTerminalAndTimeoutIsNot() {
        var rejected = exact
        rejected["status"] = "rejected"
        XCTAssertEqual(EditorialReceiptPolicy.resolution(
            project: "ttendencias", eventID: "trend-1", revision: 4,
            decision: "rework", requestID: "request-123", receipt: rejected),
            "Rechazada")
        var queued = exact
        queued["status"] = "queued"
        XCTAssertNil(EditorialReceiptPolicy.resolution(
            project: "ttendencias", eventID: "trend-1", revision: 4,
            decision: "rework", requestID: "request-123", receipt: queued))
    }

    func testSuccessfulDeletionWithExactReceiptOnly() {
        var deletion: [String: Any] = [
            "request_id": "delete-1", "project": "ttittulares",
            "event_id": "news-9", "revision": 1,
            "decision": "deleted", "status": "already_applied"
        ]
        XCTAssertEqual(EditorialReceiptPolicy.resolution(
            project: "ttittulares", eventID: "news-9", revision: 1,
            decision: "deleted", requestID: "delete-1", receipt: deletion),
            "Confirmada")
        deletion["decision"] = "published"
        XCTAssertNil(EditorialReceiptPolicy.resolution(
            project: "ttittulares", eventID: "news-9", revision: 1,
            decision: "deleted", requestID: "delete-1", receipt: deletion))
    }
}
