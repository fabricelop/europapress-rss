import XCTest
@testable import MiMapaDelTiempo

final class SmartGPSTests: XCTestCase {
    private let start = Date(timeIntervalSince1970:1_000)

    func testStationaryNinetyMinutesNeverEntersAutomaticRest() {
        var decision = SmartGPSDecision()
        decision.observe(date:start,speed:0,metersSincePrevious:0,motionMoving:false)
        decision.observe(date:start.addingTimeInterval(90*60),
                         speed:0,metersSincePrevious:0,motionMoving:false)
        XCTAssertEqual(decision.mode,.precision)
        XCTAssertFalse(GPSContinuityPolicy.pausesAutomatically)
        XCTAssertEqual(GPSContinuityPolicy.distanceFilter,kCLDistanceFilterNone)
    }

    func testCoreMotionUnavailabilityNeverDisablesGPS() {
        var decision = SmartGPSDecision()
        decision.observe(date:start,speed:0,metersSincePrevious:0,motionMoving:nil)
        decision.observe(date:start.addingTimeInterval(3600),
                         speed:0,metersSincePrevious:0,motionMoving:nil)
        XCTAssertEqual(decision.mode,.precision)
    }

    func testMovementAndAnticipationNeverChangeGPSPowerMode() {
        var decision = SmartGPSDecision()
        decision.anticipate()
        XCTAssertTrue(decision.movingSoon)
        XCTAssertEqual(decision.mode,.precision)
        decision.observe(date:start,speed:17,metersSincePrevious:80,motionMoving:true)
        XCTAssertEqual(decision.mode,.precision)
        decision.cancelAnticipation()
        XCTAssertFalse(decision.movingSoon)
        XCTAssertEqual(decision.mode,.precision)
    }

    func testSimulatedLongPauseIsDetectedNotBackfilled() {
        let later=start.addingTimeInterval(80*60)
        XCTAssertEqual(GPSContinuityPolicy.observedGap(after:start,at:later),4800)
        XCTAssertNil(GPSContinuityPolicy.observedGap(after:start,
                          at:start.addingTimeInterval(12)))
        XCTAssertNil(GPSContinuityPolicy.observedGap(after:nil,at:later))
        XCTAssertNil(GPSContinuityPolicy.observedGap(after:later,at:start))
    }

    func testShortGPSGapBoundary() {
        XCTAssertNil(GPSContinuityPolicy.observedGap(after:start,
                         at:start.addingTimeInterval(29.9)))
        XCTAssertEqual(GPSContinuityPolicy.observedGap(after:start,
                         at:start.addingTimeInterval(30)),30)
    }
}
