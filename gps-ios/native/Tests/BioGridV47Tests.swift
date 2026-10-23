import XCTest
import CoreLocation
@testable import MiMapaDelTiempo

final class BioGridV47Tests: XCTestCase {
    private func date(_ iso:String) -> Date {
        ISO8601DateFormatter().date(from:iso)!
    }

    func testLiveSecondsTickWithoutAnotherGPSOrReload() {
        let start = date("2026-10-23T08:00:00Z")
        let early = BioGridBirthTicker.project(
            remainder:0,sourceEnd:start,visitStart:start,
            latestFix:date("2026-10-23T08:04:20Z"),
            now:date("2026-10-23T08:04:20Z"),resting:false)
        XCTAssertTrue(early.running)
        XCTAssertEqual(early.provisionalBirths,0)
        XCTAssertEqual(early.secondsRemaining,40)
        let later = BioGridBirthTicker.project(
            remainder:0,sourceEnd:start,visitStart:start,
            latestFix:date("2026-10-23T08:05:02Z"),
            now:date("2026-10-23T08:05:02Z"),resting:false)
        XCTAssertTrue(later.running)
        XCTAssertEqual(later.provisionalBirths,1)
        XCTAssertEqual(later.secondsRemaining,298)
        XCTAssertEqual(later.secondsAccumulated,2,accuracy:0.001)
    }

    func testStoppedGPSNeverContinuesInfinitely() {
        let start = date("2026-10-23T08:00:00Z")
        let stale = BioGridBirthTicker.project(
            remainder:90,sourceEnd:start,visitStart:start,
            latestFix:date("2026-10-23T08:00:10Z"),
            now:date("2026-10-23T08:40:00Z"),resting:false)
        XCTAssertFalse(stale.running)
        XCTAssertEqual(stale.provisionalBirths,0)
    }

    func testHeadlinesAreCalculatedNotInvented() {
        var snapshot = BioGridSnapshot()
        snapshot.populations = ["1:2":[7,3,0,0,0,0,0],
                                "1:3":[3,0,0,0,0,0,0]]
        let first = BioGridDailyInsights.headlines(snapshot:snapshot,report:nil)
        XCTAssertEqual(first.count,2)
        XCTAssertTrue(first[0].contains("L"))
        XCTAssertTrue(first[0].contains("10"))
        var daily = BioGridDay(date:date("2026-10-22T22:00:00Z"))
        daily.conquests[1] = 3
        let second = BioGridDailyInsights.headlines(snapshot:snapshot,report:daily)
        XCTAssertEqual(second.count,2)
        XCTAssertTrue(second[1].contains("M"))
        XCTAssertTrue(second[1].contains("3"))
    }

    func testEventPlaceNamesNeverDisplayInternalCellIdentifiers() {
        let cell = Cell(row:145254,column:149255)
        let here = Grid.center(cell)
        let location = BioGridDailyInsights.location(cell,
            zoneName:nil,explicitName:nil,near:here)
        XCTAssertEqual(location,"En tu zona actual")
        let named = BioGridDailyInsights.location(cell,
            zoneName:"Mirasierra",explicitName:nil,near:nil)
        XCTAssertEqual(named,"Mirasierra")
        XCTAssertFalse(location.contains("145254:149255"))
    }
}
