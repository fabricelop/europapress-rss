import XCTest
@testable import MiMapaDelTiempo

final class BioGridV49DefensiveMigrationTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Madrid")!

    private func date(_ raw: String) -> Date {
        ISO8601DateFormatter().date(from: raw)!
    }

    private func interval(_ start: String, _ end: String, _ cell: Cell) -> AssignedInterval {
        AssignedInterval(start: date(start), end: date(end),
                         cell: cell, quality: "confirmed", source: "test")
    }

    func testRequiresTenBacteriaAndKeepsTenWhenUnopposed() {
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([9,0,0,0,0,0,0]))
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([10,0,0,0,0,0,0]))
        let eligible = BioGridEngine.defensiveMigrationLimit([11,0,0,0,0,0,0])
        XCTAssertEqual(eligible?.family,0)
        XCTAssertEqual(eligible?.maximum,1)
        let large = BioGridEngine.defensiveMigrationLimit([90,0,0,0,0,0,0])
        XCTAssertEqual(large?.maximum,80)
    }

    func testOnlySoleLeaderMayLeaveAndMustKeepThirtyPercentAdvantage() {
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([40,40,0,0,0,0,0]))
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([100,90,0,0,0,0,0]))
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([130,100,0,0,0,0,0]))
        let one = BioGridEngine.defensiveMigrationLimit([131,100,0,0,0,0,0])
        XCTAssertEqual(one?.family,0)
        XCTAssertEqual(one?.maximum,1)
        let reserve = BioGridEngine.defensiveMigrationLimit([150,100,80,0,0,0,0])
        XCTAssertEqual(reserve?.family,0)
        XCTAssertEqual(reserve?.maximum,20)
        let leaderNotFirst = BioGridEngine.defensiveMigrationLimit([120,160,0,0,0,0,0])
        XCTAssertEqual(leaderNotFirst?.family,1)
        XCTAssertEqual(leaderNotFirst?.maximum,4)
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([130,130,0,0,0,0,0]))
    }

    func testMigrationDoesNotOverflowWithHugeOpponents() {
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([
            Int64.max, Int64.max-1, 0,0,0,0,0
        ]))
    }

    func testEveryRecordedDepartureBelongsToPermittedLeaderAndRespectsReserve() {
        let center = Cell(row:145254,column:149255)
        let inputs = [
            interval("2026-10-19T08:00:00Z","2026-10-19T16:00:00Z",center),
            interval("2026-10-20T08:00:00Z","2026-10-20T16:00:00Z",center),
            interval("2026-10-21T08:00:00Z","2026-10-21T14:00:00Z",
                     Cell(row:center.row+1,column:center.column)),
            interval("2026-10-22T08:00:00Z","2026-10-22T14:00:00Z",center)
        ]
        let sim = BioGridEngine.simulate(inputs,
            now:date("2026-10-23T14:00:00Z"),timezone:zone)
        var emigrated: Int64 = 0
        for (key,records) in sim.cellDays {
            let all = sim.cellHistory[key] ?? []
            for record in records {
                let previous = all.last(where: { $0.date < record.date })?.counts
                    ?? Array(repeating:0,count:7)
                let departures = (0..<7).map { record.departed($0) }
                let total = departures.reduce(0,+)
                guard total > 0 else { continue }
                guard let permission = BioGridEngine.defensiveMigrationLimit(previous) else {
                    XCTFail("Migrated without defensible leader: \(key) \(record.date)")
                    continue
                }
                XCTAssertEqual(departures[permission.family],total,
                    "A minority family emigrated in \(key)")
                XCTAssertLessThanOrEqual(total,permission.maximum,
                    "Emigration lowered the dominant defense margin")
                emigrated += total
            }
        }
        XCTAssertGreaterThan(emigrated,0,"Expected some emigration in fixture")
        XCTAssertEqual(emigrated,sim.days.reduce(Int64(0)) {
            $0 + $1.migrated.reduce(0,+)
        })
    }

    func testNewPolicyRemainsDeterministic() throws {
        let cell=Cell(row:145254,column:149255)
        let input=[
            interval("2026-10-19T08:00:00Z","2026-10-19T17:00:00Z",cell),
            interval("2026-10-20T08:00:00Z","2026-10-20T17:00:00Z",cell)
        ]
        let a=BioGridEngine.simulate(input,now:date("2026-10-23T12:00:00Z"),timezone:zone)
        let b=BioGridEngine.simulate(input,now:date("2026-10-23T12:00:00Z"),timezone:zone)
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try encoder.encode(a.cellDays),try encoder.encode(b.cellDays))
        XCTAssertEqual(a.populations,b.populations)
    }
}
