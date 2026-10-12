
import Foundation
import XCTest
@testable import MiMapaDelTiempo

final class TimeLiveMotionTests:XCTestCase {
    private func fix(_ t:Double,_ latitude:Double,_ longitude:Double,
                     accuracy:Double=5)->GPSPoint {
        GPSPoint(date:Date(timeIntervalSince1970:t),latitude:latitude,
                 longitude:longitude,accuracy:accuracy,source:"GPS")
    }
    func testStationaryJitterDoesNotTriggerMovement() {
        let now=Date(timeIntervalSince1970:900)
        let points=[fix(700,40.4,-3.7),fix(730,40.40001,-3.70001),
                    fix(800,40.40002,-3.700015),fix(880,40.40001,-3.7)]
        let state=TimeLiveMotion.analyze(points,now:now,
            center:points.last!.cell)
        XCTAssertFalse(state.moving)
        XCTAssertEqual(state.recentDistanceMeters,0)
    }
    func testRecentWalkingCreatesTrailAndDistance() {
        let now=Date(timeIntervalSince1970:900)
        let points=[fix(600,40.4,-3.7000),fix(700,40.4,-3.6994),
                    fix(800,40.4,-3.6988),fix(880,40.4,-3.6982)]
        let state=TimeLiveMotion.analyze(points,now:now,center:points.last!.cell)
        XCTAssertTrue(state.moving)
        XCTAssertGreaterThan(state.recentDistanceMeters,100)
        XCTAssertGreaterThan(state.crossedCells,0)
        XCTAssertNotNil(state.headingDegrees)
        XCTAssertTrue(state.trailIndices.allSatisfy { (0..<9).contains($0) })
    }
    func testStaleMovementDoesNotShowMoving() {
        let now=Date(timeIntervalSince1970:1800)
        let points=[fix(600,40.4,-3.7),fix(700,40.4,-3.6994),
                    fix(800,40.4,-3.6988)]
        let state=TimeLiveMotion.analyze(points,now:now,center:points.last!.cell)
        XCTAssertFalse(state.moving)
    }
    func testInaccurateOrTeleportSamplesIgnored() {
        let now=Date(timeIntervalSince1970:900)
        let points=[fix(700,40.4,-3.7),fix(800,40.5,-3.7),
                    fix(880,40.6,-3.7,accuracy:400)]
        let state=TimeLiveMotion.analyze(points,now:now,center:points.last!.cell)
        XCTAssertFalse(state.moving)
        XCTAssertEqual(state.recentDistanceMeters,0)
    }
    func testHourlyMinutesContainNoEstimatedTime() {
        let now=Date(timeIntervalSince1970:21600)
        let row=1,col=2
        let interval=AssignedInterval(start:now.addingTimeInterval(-1800),
            end:now,cell:Cell(row:row,column:col),
            quality:"observado",source:"GPS")
        let values=TimeLiveVisualization.hourlyMinutes(intervals:[interval],
            cellIDs:[interval.cell.id],endingAt:now)
        XCTAssertEqual(values,[0,0,0,0,0,30])
    }
}
