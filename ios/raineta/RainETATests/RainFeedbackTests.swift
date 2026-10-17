import XCTest
@testable import RainETA

final class RainFeedbackTests: XCTestCase {
    func testOneReportOnlyOverridesNowAndFiveLocalReportsCanCalibrate() {
        let now = Date(timeIntervalSince1970:1_800_000_000)
        let reports=(0..<5).map { index in
            RainReport(date:now.addingTimeInterval(Double(-index * 3600)),
                       latitude:40.4168,longitude:-3.7038,
                       raining:true,modelWet:["A":true,"B":false])
        }
        let first=RainFeedback.weights(Array(reports.prefix(1)),
            latitude:40.4168,longitude:-3.7038,now:now)
        XCTAssertLessThan(first["B"] ?? 1,1)
        XCTAssertGreaterThan(first["A"] ?? 1,1)
        let weights=RainFeedback.weights(reports,latitude:40.4168,
                                         longitude:-3.7038,now:now)
        XCTAssertGreaterThan(weights["A"] ?? 0,weights["B"] ?? 0)
        XCTAssertLessThanOrEqual(weights["A"] ?? 0,1.25)
        XCTAssertTrue(RainFeedback.weights(reports,latitude:41.0,
            longitude:-3.7038,now:now).isEmpty)
    }

    func testRecentCorrectionTemporarilyPenalizesWrongModelThenExpires() {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let report=RainReport(date:now,latitude:40.4168,longitude:-3.7038,
                              raining:false,modelWet:["Wet":true,"Dry":false])
        let current=RainFeedback.weights([report],latitude:40.4168,
                                         longitude:-3.7038,now:now)
        XCTAssertEqual(current["Wet"] ?? 0,0.65,accuracy:0.001)
        XCTAssertEqual(current["Dry"] ?? 0,1.12,accuracy:0.001)
        let later=RainFeedback.weights([report],latitude:40.4168,
                                       longitude:-3.7038,
                                       now:now.addingTimeInterval(20*60))
        XCTAssertTrue(later.isEmpty)
    }
}
