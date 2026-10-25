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
            timerValidUntil:start.addingTimeInterval(120),lastGPSAt:start,resting:false,
            nearbyIntensity:[0,1,2,1,4,2,0,2,0],
            lastSixHours:[0,25,65,100,100,20],chartIsZone:true,
            moving:false,recentDistanceMeters:0,crossedCells:0,
            trailIndices:[],headingDegrees:nil,currentZoneStaySeconds:300,
            lastSixMinutes:[0,15,39,60,60,12],milestone:nil,
            siteName:"Casa Montevalle",siteConfirmed:true,
            bioGridCounts:[2,3,5,7,11,13,17],bioGridUpdatedAt:start)
        let bytes=try! JSONEncoder().encode(state)
        let decoded=try! JSONDecoder().decode(TimeMapActivityAttributes.ContentState.self,from:bytes)
        XCTAssertEqual(decoded,state)
        XCTAssertEqual(decoded.confirmedZoneSeconds,1800)
        XCTAssertEqual(decoded.nearbyIntensity.count,9)
        XCTAssertEqual(decoded.lastSixHours.count,6)
        XCTAssertEqual(decoded.siteName,"Casa Montevalle")
        XCTAssertEqual(decoded.bioGridCounts,[2,3,5,7,11,13,17])
    }
    func testLiveHeadlineShowsSavedPlaceInsteadOfTechnicalCellLabel() {
        XCTAssertEqual(TimeLiveCompactPresentation.title(
            site:"Casa Montevalle",fallback:"Cuadrícula 1"),"Casa Montevalle")
        XCTAssertEqual(TimeLiveCompactPresentation.title(
            site:nil,fallback:"Cuadrícula 1"),"Cuadrícula 1")
        XCTAssertEqual(TimeLiveCompactPresentation.title(
            site:"  ",fallback:"Cuadrícula 1"),"Cuadrícula 1")
    }
    func testProposedPlaceIsClearlyDistinctFromManualConfirmation() {
        XCTAssertTrue(TimeLiveCompactPresentation.isProposed(
            site:"SAP España",confirmed:false))
        XCTAssertFalse(TimeLiveCompactPresentation.isProposed(
            site:"SAP España",confirmed:true))
        XCTAssertFalse(TimeLiveCompactPresentation.isProposed(
            site:nil,confirmed:nil))
    }
    func testCompactLiveRequiresExactlySevenNonnegativeFamilies() {
        XCTAssertNil(TimeLiveCompactPresentation.families(nil))
        XCTAssertNil(TimeLiveCompactPresentation.families([1,2,3]))
        XCTAssertEqual(TimeLiveCompactPresentation.families(
            [3,-5,2,0,1,10,6]),[3,0,2,0,1,10,6])
    }

    func testUnavailableZoneIsNotFalselyReported() {
        let start=Date(timeIntervalSince1970:10000)
        let state=TimeMapActivityAttributes.ContentState(
            cellName:"Cuadrícula 12",cellNumber:"Cuadrícula 12",
            zoneName:nil,confirmedCellSeconds:20,confirmedZoneSeconds:nil,
            stayStartedAt:start,timerValidUntil:start.addingTimeInterval(120),
            lastGPSAt:start,resting:false,
            nearbyIntensity:Array(repeating:0,count:9),
            lastSixHours:Array(repeating:0,count:6),chartIsZone:false,
            moving:false,recentDistanceMeters:0,crossedCells:0,
            trailIndices:[],headingDegrees:nil,currentZoneStaySeconds:nil,
            lastSixMinutes:Array(repeating:0,count:6),milestone:nil,
            siteName:nil,siteConfirmed:nil,bioGridCounts:nil,bioGridUpdatedAt:nil)
        XCTAssertNil(state.confirmedZoneSeconds)
        XCTAssertNil(state.zoneName)
    }
}
