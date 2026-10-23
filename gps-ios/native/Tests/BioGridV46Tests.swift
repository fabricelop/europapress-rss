import XCTest
@testable import MiMapaDelTiempo

final class BioGridV46Tests:XCTestCase {
    private func timestamp(_ string:String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from:string)!
    }

    private func interval(_ start:String,_ end:String,_ cell:Cell) -> AssignedInterval {
        AssignedInterval(start:timestamp(start),end:timestamp(end),
                         cell:cell,quality:"confirmed",source:"test")
    }

    func testTodayBirthsAndSevenFamiliesAreGeneratedWithoutExtraGPS() {
        let cell = Cell(row:1000,column:2000)
        let samples = [
            interval("2026-10-19T10:00:00Z","2026-10-19T10:10:00Z",cell),
            interval("2026-10-20T10:00:00Z","2026-10-20T10:05:00Z",cell)
        ]
        let snapshot = BioGridEngine.simulate(samples,
            now:timestamp("2026-10-20T15:00:00Z"),
            timezone:TimeZone(identifier:"Europe/Madrid")!)
        XCTAssertEqual(snapshot.days.count,2)
        XCTAssertEqual(snapshot.days[0].births[0],2)
        XCTAssertEqual(snapshot.days[1].births[1],1)
        XCTAssertEqual(snapshot.todayBirths[cell.id]?[1],1)
        XCTAssertEqual(snapshot.days.reduce(Int64(0), { $0 + $1.births.reduce(0,+) }),3)
        XCTAssertEqual(snapshot.historical.count,2)
        XCTAssertFalse(snapshot.territoryEvents.isEmpty)
        XCTAssertEqual(snapshot.remainingSeconds[cell.id] ?? -1,0,accuracy:0.001)
    }

    func testReplayingTheSameInputIsDeterministic() {
        let cell = Cell(row:1000,column:2000)
        let samples = [
            interval("2026-10-19T10:00:00Z","2026-10-19T13:00:00Z",cell),
            interval("2026-10-20T10:00:00Z","2026-10-20T13:00:00Z",cell)
        ]
        let now = timestamp("2026-10-23T12:00:00Z")
        let zone = TimeZone(identifier:"Europe/Madrid")!
        let a = BioGridEngine.simulate(samples,now:now,timezone:zone)
        let b = BioGridEngine.simulate(samples,now:now,timezone:zone)
        XCTAssertEqual(a.populations,b.populations)
        XCTAssertEqual(a.historical.map(\.population),b.historical.map(\.population))
        XCTAssertEqual(a.territoryEvents.map(\.id),b.territoryEvents.map(\.id))
        XCTAssertEqual(a.cellHistory[cell.id]?.last?.counts,b.cellHistory[cell.id]?.last?.counts)
    }

    func testNoRealTimeBirthsAreSilentlyInventedFromMissingGPSIntervals() {
        let cell = Cell(row:1000,column:2000)
        let snapshot = BioGridEngine.simulate(
            [interval("2026-10-19T10:00:00Z","2026-10-19T10:04:00Z",cell)],
            now:timestamp("2026-10-19T15:00:00Z"))
        XCTAssertTrue(snapshot.populations.isEmpty)
        XCTAssertTrue(snapshot.todayBirths.isEmpty)
    }
}
