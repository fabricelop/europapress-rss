import Foundation
import XCTest
@testable import MiMapaDelTiempo

final class TimeActivityFingerprintTests:XCTestCase {
    func testSameCellAndNameButNewVisitResetsTimer() {
        let first=TimeActivityFingerprint(cellID:"1:2",visibleName:"Casa",
            startedAt:Date(timeIntervalSince1970:1000),resting:false)
        let returned=TimeActivityFingerprint(cellID:"1:2",visibleName:"Casa",
            startedAt:Date(timeIntervalSince1970:2000),resting:false)
        XCTAssertNotEqual(first,returned)
    }
    func testCellChangeDetectedEvenWithSameLabel() {
        let start=Date(timeIntervalSince1970:1000)
        let first=TimeActivityFingerprint(cellID:"1:2",visibleName:"Zona",
            startedAt:start,resting:false)
        let second=TimeActivityFingerprint(cellID:"1:3",visibleName:"Zona",
            startedAt:start,resting:false)
        XCTAssertNotEqual(first,second)
    }
    func testRestingChangeTriggersUpdate() {
        let start=Date(timeIntervalSince1970:1000)
        let live=TimeActivityFingerprint(cellID:"1:2",visibleName:"Zona",
            startedAt:start,resting:false)
        let rest=TimeActivityFingerprint(cellID:"1:2",visibleName:"Zona",
            startedAt:start,resting:true)
        XCTAssertNotEqual(live,rest)
        XCTAssertEqual(rest,rest)
    }
}
