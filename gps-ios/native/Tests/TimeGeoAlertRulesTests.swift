import XCTest
@testable import MiMapaDelTiempo
final class TimeGeoAlertRulesTests:XCTestCase {
    func testEntryRequiresActualChangeAndPreviousObservation() {
        XCTAssertFalse(GeoAlertRules.zoneEntered(previous:nil,current:"A"))
        XCTAssertTrue(GeoAlertRules.zoneEntered(previous:"none",current:"A"))
        XCTAssertFalse(GeoAlertRules.zoneEntered(previous:"A",current:"A"))
        XCTAssertTrue(GeoAlertRules.zoneEntered(previous:"A",current:"B"))
    }
    func testStayThresholdNeverTriggersBeforeLimit() {
        XCTAssertFalse(GeoAlertRules.stayReached(3599,minutes:60))
        XCTAssertTrue(GeoAlertRules.stayReached(3600,minutes:60))
        XCTAssertFalse(GeoAlertRules.stayReached(10_000,minutes:0))
    }
}
