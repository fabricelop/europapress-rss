import Foundation
import XCTest
@testable import MiMapaDelTiempo

final class LiveActivityPresentationTests:XCTestCase {
    func testContentCarriesConfirmedCellAndZoneTotals() {
        let start=Date(timeIntervalSince1970:10000)
        let state=TimeMapActivityAttributes.ContentState(
            cellName:"Montevalle",cellNumber:"Cuadrícula 397",
            zoneName:"Montevalle",confirmedCellSeconds:45,
            confirmedZoneSeconds:1800,stayStartedAt:start,
            timerValidUntil:start.addingTimeInterval(120),lastGPSAt:start,resting:false)
        let bytes=try! JSONEncoder().encode(state)
        let decoded=try! JSONDecoder().decode(TimeMapActivityAttributes.ContentState.self,from:bytes)
        XCTAssertEqual(decoded,state)
        XCTAssertEqual(decoded.confirmedZoneSeconds,1800)
    }
    func testUnavailableZoneIsNotFalselyReported() {
        let start=Date(timeIntervalSince1970:10000)
        let state=TimeMapActivityAttributes.ContentState(
            cellName:"Cuadrícula 12",cellNumber:"Cuadrícula 12",
            zoneName:nil,confirmedCellSeconds:20,confirmedZoneSeconds:nil,
            stayStartedAt:start,timerValidUntil:start.addingTimeInterval(120),
            lastGPSAt:start,resting:false)
        XCTAssertNil(state.confirmedZoneSeconds)
        XCTAssertNil(state.zoneName)
    }
}
