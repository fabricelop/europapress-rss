import XCTest
@testable import MiMapaDelTiempo

final class BioGridV51DoubleDominanceTests: XCTestCase {
    private func iso(_ value:String)->Date {
        ISO8601DateFormatter().date(from:value)!
    }
    private func visit(_ start:String, _ end:String, _ cell:Cell)->AssignedInterval {
        AssignedInterval(start:iso(start),end:iso(end),
                         cell:cell,quality:"confirmed",source:"test")
    }

    func testDoublePopulationNeededBeforeAndAfterLeaving() {
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([199,100,0,0,0,0,0]))
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([200,100,0,0,0,0,0]))
        XCTAssertEqual(BioGridEngine.defensiveMigrationLimit([201,100,0,0,0,0,0])?.maximum,1)
        XCTAssertEqual(BioGridEngine.defensiveMigrationLimit([500,200,0,0,0,0,0])?.maximum,100)
        XCTAssertEqual(BioGridEngine.defensiveMigrationLimit([301,150,0,0,0,0,0])?.maximum,1)
        XCTAssertEqual(BioGridEngine.defensiveMigrationLimit([11,0,0,0,0,0,0])?.maximum,1)
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([10,0,0,0,0,0,0]))
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([80,80,0,0,0,0,0]))
        XCTAssertNil(BioGridEngine.defensiveMigrationLimit([
            Int64.max, Int64.max-1, 0,0,0,0,0
        ]))
    }

    func testTwentyPercentStrictCapAndVariableChance() {
        XCTAssertEqual(BioGridEngine.migrationTwentyPercentCap(0),0)
        XCTAssertEqual(BioGridEngine.migrationTwentyPercentCap(4),0)
        XCTAssertEqual(BioGridEngine.migrationTwentyPercentCap(5),1)
        XCTAssertEqual(BioGridEngine.migrationTwentyPercentCap(99),19)
        XCTAssertEqual(BioGridEngine.migrationTwentyPercentCap(100),20)
        XCTAssertEqual(BioGridEngine.migrationTwentyPercentCap(501),100)
        for population:Int64 in [0,1,10,50,100,500,1_000,100_000] {
            let chance=BioGridEngine.migrationProbability(totalPopulation:population)
            XCTAssertGreaterThanOrEqual(chance,0)
            XCTAssertLessThan(chance,0.20)
        }
        XCTAssertEqual(BioGridEngine.migrationProbability(totalPopulation:100),0.20*100/230.0,
                       accuracy:0.00000001)
    }

    func testRecordedMigrantsRespectDoubleReserveAndTwentyPercentEachNight() {
        let center=Cell(row:145254,column:149255)
        let north=BioGridEngine.neighbor(center,direction:0)
        let visits=[
            visit("2026-10-19T08:00:00Z","2026-10-19T18:00:00Z",center),
            visit("2026-10-20T08:00:00Z","2026-10-20T18:00:00Z",center),
            visit("2026-10-21T08:00:00Z","2026-10-21T12:00:00Z",north),
            visit("2026-10-22T08:00:00Z","2026-10-22T14:00:00Z",center)
        ]
        let madrid=TimeZone(identifier:"Europe/Madrid")!
        let snap=BioGridEngine.simulate(visits,now:iso("2026-10-23T14:00:00Z"),
                                        timezone:madrid)
        var found:Int64=0
        for (key,history) in snap.cellDays {
            let populations=snap.cellHistory[key] ?? []
            for day in history {
                let prior=populations.last(where:{$0.date<day.date})?.counts ??
                    Array(repeating:Int64(0),count:7)
                let emigrated=(0..<7).map { day.departed($0) }
                let total=emigrated.reduce(Int64(0),+)
                guard total>0 else { continue }
                guard let permit=BioGridEngine.defensiveMigrationLimit(prior) else {
                    XCTFail("Leaving without double leadership in \(key)")
                    continue
                }
                XCTAssertEqual(emigrated[permit.family],total,
                               "Minority migration in \(key)")
                XCTAssertLessThanOrEqual(total,permit.maximum,
                                         "Migration compromised double reserve in \(key)")
                XCTAssertLessThanOrEqual(total,
                    BioGridEngine.migrationTwentyPercentCap(prior[permit.family]),
                    "More than 20% migrated from \(key)")
                found += total
            }
        }
        XCTAssertGreaterThan(found,0)
        let emigrants=snap.days.reduce(Int64(0)) { total,day in
            total+day.migrated.reduce(0,+)
        }
        XCTAssertEqual(found,emigrants)
        let born=snap.days.reduce(Int64(0)) {$0+$1.births.reduce(0,+)}
        let dead=snap.days.reduce(Int64(0)) {$0+$1.deaths.reduce(0,+)}
        let living=snap.populations.values.reduce(Int64(0)) {$0+$1.reduce(0,+)}
        XCTAssertEqual(living,born-dead)
    }

    func testDeterministicUnderNewMigrationRules() throws {
        let cell=Cell(row:145254,column:149255)
        let data=[
            visit("2026-10-19T08:00:00Z","2026-10-19T16:00:00Z",cell),
            visit("2026-10-20T08:00:00Z","2026-10-20T16:00:00Z",cell)
        ]
        let now=iso("2026-10-23T12:00:00Z")
        let a=BioGridEngine.simulate(data,now:now)
        let b=BioGridEngine.simulate(data,now:now)
        let coder=JSONEncoder()
        coder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(a.populations,b.populations)
        XCTAssertEqual(try coder.encode(a.cellDays),
                       try coder.encode(b.cellDays))
    }
}