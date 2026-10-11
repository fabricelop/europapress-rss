import XCTest
import CoreLocation
@testable import MiMapaDelTiempo

final class GPSRestPolicyTests: XCTestCase {
    func testTenHoursAddOnlyToRestingCellWithoutGpsFixes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(10 * 3600)
        XCTAssertEqual(GPSRestPolicy.elapsed(start:start,end:end),36000)
        XCTAssertEqual(GPSRestPolicy.elapsed(start:start,end:end,
            lowerBound:start.addingTimeInterval(9*3600)),3600)
    }

    func testRestNeverCountsBeforeItsStartOrAfterClockRollback() {
        let start=Date(timeIntervalSince1970:1000)
        XCTAssertEqual(GPSRestPolicy.elapsed(start:start,end:start.addingTimeInterval(-5)),0)
        XCTAssertEqual(GPSRestPolicy.elapsed(start:start,end:start),0)
    }

    func testGeofenceFallbackNeedsReliableMovement() {
        XCTAssertFalse(GPSRestPolicy.shouldResume(distance:100,accuracy:10))
        XCTAssertFalse(GPSRestPolicy.shouldResume(distance:200,accuracy:150))
        XCTAssertFalse(GPSRestPolicy.shouldResume(distance:190,accuracy:110))
        XCTAssertTrue(GPSRestPolicy.shouldResume(distance:210,accuracy:15))
        XCTAssertTrue(GPSRestPolicy.shouldResume(distance:240,accuracy:110))
    }

    func testRestRecordSurvivesEncoding() throws {
        let saved=GPSRestSession(startedAt:Date(timeIntervalSince1970:123),
             cell:Cell(row:42,column:5),latitude:40.5,longitude:-3.3)
        let restored=try JSONDecoder().decode(GPSRestSession.self,
                                            from:JSONEncoder().encode(saved))
        XCTAssertEqual(restored,saved)
    }
}
