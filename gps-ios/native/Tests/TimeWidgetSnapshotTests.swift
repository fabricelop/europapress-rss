import XCTest
@testable import MiMapaDelTiempo

final class TimeWidgetSnapshotTests: XCTestCase {
    func testTimeFormatDoesNotShowLeadingZeroUnits() {
        XCTAssertEqual(TimeWidgetDuration.readable(85), "1 min 25 s")
        XCTAssertEqual(TimeWidgetDuration.compact(85), "1m 25s")
        XCTAssertEqual(TimeWidgetDuration.readable(0), "0 s")
        XCTAssertEqual(TimeWidgetDuration.readable(3_661), "1 h 1 min 1 s")
    }

    func testSnapshotCodableAndRecency() throws {
        let moment = Date(timeIntervalSince1970:10_000)
        let sample = TimeWidgetSnapshot(
            recordedAt:moment,totalAssignedSeconds:3_000,
            currentCellSeconds:900,currentStaySeconds:80,
            currentCellName:"Casa",lastLocationAt:moment,
            trackingEnabled:true,hasFix:true)
        let copy = try JSONDecoder().decode(TimeWidgetSnapshot.self,
                         from:JSONEncoder().encode(sample))
        XCTAssertEqual(sample, copy)
        XCTAssertTrue(copy.locationIsRecent(at:moment.addingTimeInterval(160)))
        XCTAssertFalse(copy.locationIsRecent(at:moment.addingTimeInterval(300)))
    }

    func testNoCurrentStayWithoutValidFix() {
        let empty = TimeWidgetSnapshot.empty()
        XCTAssertNil(empty.currentStaySeconds)
        XCTAssertFalse(empty.locationIsRecent(at:.now))
    }
}
