import XCTest
@testable import MiMapaDelTiempo

final class BioGridV48LedgerTests: XCTestCase {
    private let madrid: TimeZone = TimeZone(identifier:"Europe/Madrid")!

    private func date(_ iso:String)->Date {
        ISO8601DateFormatter().date(from:iso)!
    }
    private func interval(_ a:String,_ b:String,_ cell:Cell)->AssignedInterval {
        AssignedInterval(start:date(a),end:date(b),
            cell:cell,quality:"confirmed",source:"test")
    }

    private var testSource:[AssignedInterval] {
        let center = Cell(row:145254,column:149255)
        return [
            interval("2026-10-19T08:00:00Z","2026-10-19T16:00:00Z",center),
            interval("2026-10-20T08:00:00Z","2026-10-20T16:00:00Z",center),
            interval("2026-10-21T08:00:00Z","2026-10-21T14:00:00Z",
                     Cell(row:center.row+1,column:center.column)),
            interval("2026-10-22T08:00:00Z","2026-10-22T14:00:00Z",center)
        ]
    }

    private func simulate()->BioGridSnapshot {
        BioGridEngine.simulate(testSource,now:date("2026-10-23T14:00:00Z"),
                             timezone:madrid)
    }

    func testAllFamilyDayBalancesMatchPreviousClosingPopulation() {
        let sim = simulate()
        var checked = 0
        for (key, entries) in sim.cellDays {
            let history = sim.cellHistory[key] ?? []
            for record in entries {
                let before = history.last(where:{$0.date<record.date})?.counts ??
                    Array(repeating:0,count:7)
                let after = history.last(where:{$0.date<=record.date})?.counts ??
                    Array(repeating:0,count:7)
                for family in 0..<7 {
                    XCTAssertEqual(after[family],before[family]+record.delta(family),
                        "Balance incorrecto cuadrícula \(key), familia \(family), \(record.date)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked,3)
    }

    func testDirectionalDeparturesAreExactlyNeighborsOppositeArrivals() {
        let sim = simulate()
        let reverse = [1,0,3,2]
        let dr = [1,-1,0,0]
        let dc = [0,0,1,-1]
        var checkedMoves:Int64 = 0
        for (key,entries) in sim.cellDays {
            let parts = key.split(separator:":")
            guard parts.count == 2,
                  let row=Int(parts[0]),let col=Int(parts[1]) else {
                XCTFail("Invalid grid key")
                continue
            }
            for record in entries {
                for f in 0..<7 {
                    for d in 0..<4 {
                        let out = record.departures[f][d]
                        guard out > 0 else { continue }
                        let neighbor = Cell(row:row+dr[d],column:col+dc[d]).id
                        let target = sim.cellDays[neighbor]?.first(where:{
                            $0.date==record.date
                        })
                        XCTAssertEqual(target?.arrivals[f][reverse[d]],out,
                            "Directional mismatch \(key) -> \(neighbor)")
                        checkedMoves += out
                    }
                }
            }
        }
        XCTAssertGreaterThan(checkedMoves,0)
        XCTAssertEqual(checkedMoves,sim.days.reduce(0) {
            $0+$1.migrated.reduce(0,+)
        })
    }

    func testPopulationConservationAndDayColumnTotals() {
        let sim = simulate()
        let born = sim.days.reduce(Int64(0)) {
            $0+$1.births.reduce(0,+)
        }
        let died = sim.days.reduce(Int64(0)) {
            $0+$1.deaths.reduce(0,+)
        }
        let survivors = sim.populations.values.reduce(Int64(0)) {
            $0+$1.reduce(0,+)
        }
        XCTAssertEqual(survivors,born-died)
        for report in sim.days {
            let records = sim.cellDays.values.flatMap {
                $0.filter { $0.date==report.date }
            }
            XCTAssertEqual(records.reduce(Int64(0)) {
                $0+$1.births.reduce(0,+)
            },report.births.reduce(0,+))
            XCTAssertEqual(records.reduce(Int64(0)) {
                $0+$1.deaths.reduce(0,+)
            },report.deaths.reduce(0,+))
            let outbound = records.reduce(Int64(0)) {
                $0+$1.departures.flatMap{$0}.reduce(0,+)
            }
            let inbound = records.reduce(Int64(0)) {
                $0+$1.arrivals.flatMap{$0}.reduce(0,+)
            }
            XCTAssertEqual(inbound,outbound)
        }
    }

    func testReplayHasTheSameDailyAndDirectionalLedger() {
        let left=simulate(),right=simulate()
        XCTAssertEqual(left.populations,right.populations)
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try encoder.encode(left.cellDays),
                       try encoder.encode(right.cellDays))
        XCTAssertEqual(left.historical.map(\.population),
                       right.historical.map(\.population))
    }
}
