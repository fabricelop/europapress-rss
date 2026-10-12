import XCTest
@testable import MiMapaDelTiempo

final class TimeMapCardUITests:XCTestCase {
    func testClockShowsHoursMinutesSeconds() {
        XCTAssertEqual(TimeMapCardClock.display(0),"00:00:00")
        XCTAssertEqual(TimeMapCardClock.display(59.9),"00:00:59")
        XCTAssertEqual(TimeMapCardClock.display(3601),"01:00:01")
        XCTAssertEqual(TimeMapCardClock.display(14*3600+21*60+39),"14:21:39")
    }
    func testLongAccumulatedTimeDoesNotWrapAt24Hours() {
        XCTAssertEqual(TimeMapCardClock.display(49*3600+65),"49:01:05")
    }
    func testNonFiniteAndNegativeDurationsAreSafe() {
        XCTAssertEqual(TimeMapCardClock.display(-12),"00:00:00")
        XCTAssertEqual(TimeMapCardClock.display(.infinity),"—")
    }
    func testThreeCardPresentationsAreDistinct() {
        XCTAssertNotEqual(TimeMapCardSize.minimized,.compact)
        XCTAssertNotEqual(TimeMapCardSize.compact,.expanded)
    }
}
