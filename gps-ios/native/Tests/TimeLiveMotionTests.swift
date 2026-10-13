
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
    func testSlowWalkingWithCompactedFixesSwitchesToMoving() {
        // Registro real: se retiene un fix cada ~16 m con precisión ±10 m.
        // La antigua condición exigía 24 m en cada par y nunca activaba el modo.
        let now=Date(timeIntervalSince1970:900)
        let points=(0..<7).map { i in
            fix(730+Double(i)*25,40.4+Double(i)*0.00015,-3.7,accuracy:10)
        }
        let state=TimeLiveMotion.analyze(points,now:now,center:points.last!.cell)
        XCTAssertTrue(state.moving)
        XCTAssertGreaterThanOrEqual(state.recentDistanceMeters,70)
    }
    func testWalkingWithTwentyMeterAccuracyGroupsFixes() {
        // A ±20 m, dos posiciones separadas 16 m son insuficientes por
        // separado; el ancla permite observar desplazamiento real acumulado.
        let now=Date(timeIntervalSince1970:900)
        let points=(0..<8).map { i in
            fix(730+Double(i)*20,40.4+Double(i)*0.000145,-3.7,accuracy:20)
        }
        let state=TimeLiveMotion.analyze(points,now:now,center:points.last!.cell)
        XCTAssertTrue(state.moving)
        XCTAssertGreaterThanOrEqual(state.recentDistanceMeters,60)
    }
    func testCurrentGPSFixIsUsedBeforeHistoryCompaction() {
        let now=Date(timeIntervalSince1970:900)
        let stored=[fix(760,40.4,-3.7,accuracy:8),
                    fix(800,40.40024,-3.7,accuracy:8)]
        let current=fix(880,40.40053,-3.7,accuracy:8)
        let withoutCurrent=TimeLiveMotion.analyze(stored,now:now,
            center:current.cell)
        let withCurrent=TimeLiveMotion.analyze(stored,now:now,
            center:current.cell,latest:current)
        XCTAssertFalse(withoutCurrent.moving)
        XCTAssertTrue(withCurrent.moving)
    }
    func testInaccurateStationaryJitterStillRejected() {
        let now=Date(timeIntervalSince1970:900)
        let points:[GPSPoint]=(0..<8).map { i -> GPSPoint in
            let seconds:Double=730.0+Double(i)*20.0
            let latitude:Double=40.4+(Double(i%3)-1.0)*0.00004
            let longitude:Double = -3.7+Double(i%2)*0.00003
            return fix(seconds,latitude,longitude,accuracy:20)
        }
        XCTAssertFalse(TimeLiveMotion.analyze(points,now:now,
            center:points.last!.cell).moving)
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
