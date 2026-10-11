import XCTest
@testable import MiMapaDelTiempo

final class TimeAnalyticsTests: XCTestCase {
    private func segment(_ start:Double,_ end:Double) -> AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:start),
                         end:Date(timeIntervalSince1970:end),
                         cell:Cell(row:10,column:20),quality:"observado",source:"test")
    }
    func testCutIntervalExactlyAtPeriodBoundaries() {
        let result=TimeAnalytics.totals([segment(0,100),segment(100,200)],
            from:Date(timeIntervalSince1970:50),to:Date(timeIntervalSince1970:150))
        XCTAssertEqual(result["10:20"],100)
    }
    func testDiscardOutOfRangeIntervals() {
        XCTAssertTrue(TimeAnalytics.totals([segment(0,100)],
            from:Date(timeIntervalSince1970:120),to:Date(timeIntervalSince1970:200)).isEmpty)
    }
    func testAllWindowUnbounded() {
        XCTAssertNil(TimeAnalytics.window(for:.all,now:.now))
    }
}
