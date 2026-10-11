import XCTest
@testable import MiMapaDelTiempo

final class SmartGPSTests: XCTestCase {
    func testAnticipationAndAutomaticRest() {
        var decision = SmartGPSDecision()
        let start = Date(timeIntervalSince1970:1000)
        decision.anticipate()
        XCTAssertTrue(decision.movingSoon)
        decision.observe(date:start,speed:0,metersSincePrevious:0,motionMoving:false)
        decision.observe(date:start.addingTimeInterval(601),speed:0,metersSincePrevious:0,motionMoving:false)
        XCTAssertEqual(decision.mode,.rest)
        XCTAssertFalse(decision.movingSoon)
    }
    func testMovementRestoresPrecisionWithoutSwitch() {
        var decision=SmartGPSDecision()
        let start=Date(timeIntervalSince1970:1000)
        decision.observe(date:start,speed:0,metersSincePrevious:0,motionMoving:false)
        decision.observe(date:start.addingTimeInterval(601),speed:0,metersSincePrevious:0,motionMoving:false)
        decision.observe(date:start.addingTimeInterval(602),speed:2.2,metersSincePrevious:2,motionMoving:true)
        XCTAssertEqual(decision.mode,.precision)
    }
    func testCancelPreflightDoesNotStopTracking() {
        var decision=SmartGPSDecision()
        decision.anticipate()
        decision.cancelAnticipation()
        XCTAssertEqual(decision.mode,.precision)
        XCTAssertFalse(decision.movingSoon)
    }
    func testBriefStopDoesNotEnableRest() {
        var decision=SmartGPSDecision()
        let t=Date(timeIntervalSince1970:1000)
        decision.observe(date:t,speed:0,metersSincePrevious:0,motionMoving:false)
        decision.observe(date:t.addingTimeInterval(120),speed:0,metersSincePrevious:0,motionMoving:false)
        XCTAssertEqual(decision.mode,.precision)
    }
}