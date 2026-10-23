import XCTest
@testable import MiMapaDelTiempo

final class BioGridV50FrontierBattleTests: XCTestCase {
    private func counts(_ family:Int,_ count:Int64) -> [Int64] {
        var values=Array(repeating:Int64(0),count:7)
        values[family]=count
        return values
    }

    private func cell(_ r:Int,_ c:Int) -> Cell { Cell(row:r,column:c) }

    func testEnemyAndEmptyCellsTakePriorityOverFriendlyReinforcements() {
        let source=cell(100,100)
        let north=BioGridEngine.neighbor(source,direction:0)
        let south=BioGridEngine.neighbor(source,direction:1)
        let west=BioGridEngine.neighbor(source,direction:3)
        let existing:[String:[Int64]] = [
            source.id:counts(3,150),
            north.id:counts(3,50),  // propia débil, pero hay enemigos
            south.id:counts(2,200), // rival
            west.id:counts(3,20)    // propia aún más débil
            // este vacío
        ]
        let possible=BioGridEngine.migrationTargets(cell:source,family:3,
            populations:existing,rulers:[:])
        XCTAssertEqual(possible,[1,2])
    }

    func testFriendsReinforcedOnlyAtWeakestCellAndWhenOriginIsLarger() {
        let source=cell(100,100)
        var existing:[String:[Int64]]=[source.id:counts(3,150)]
        for direction in 0..<4 {
            let neighbor=BioGridEngine.neighbor(source,direction:direction)
            existing[neighbor.id]=counts(3,[70,20,40,20][direction])
        }
        let destinations=BioGridEngine.migrationTargets(cell:source,family:3,
            populations:existing,rulers:[:])
        XCTAssertEqual(destinations,[1,3])
        existing[source.id]=counts(3,15)
        XCTAssertEqual(BioGridEngine.migrationTargets(cell:source,family:3,
            populations:existing,rulers:[:]),[])
    }

    func testConflictEscalationIsGroundedInPreviousBirthsAndImmigration() {
        let zero=[Int64](repeating:0,count:7)
        var births=zero;births[4]=9
        var friendly=zero;friendly[3]=8
        var hostile=zero;hostile[2]=2

        XCTAssertEqual(BioGridEngine.conflictType(previousBirths:zero,
            arrivals:zero,defendingFamily:3),.skirmish)
        XCTAssertEqual(BioGridEngine.conflictType(previousBirths:births,
            arrivals:zero,defendingFamily:3),.births)
        XCTAssertEqual(BioGridEngine.conflictType(previousBirths:zero,
            arrivals:friendly,defendingFamily:3),.reinforcement)
        XCTAssertEqual(BioGridEngine.conflictType(previousBirths:births,
            arrivals:hostile,defendingFamily:3),.invasion)
        XCTAssertEqual(BioGridEngine.Conflict.skirmish.risk.upperBound,0.02)
        XCTAssertEqual(BioGridEngine.Conflict.births.risk.upperBound,0.06)
        XCTAssertEqual(BioGridEngine.Conflict.reinforcement.risk.upperBound,0.07)
        XCTAssertEqual(BioGridEngine.Conflict.invasion.risk.upperBound,0.15)
    }

    private func date(_ raw:String)->Date { ISO8601DateFormatter().date(from:raw)! }
    private func interval(_ start:String,_ end:String,_ at:Cell)->AssignedInterval {
        AssignedInterval(start:date(start),end:date(end),
            cell:at,quality:"confirmed",source:"test")
    }

    func testNewPoliciesConservePopulationAndDirectionalMovements() throws {
        let base=cell(100,100)
        let input=[
            interval("2026-10-19T08:00:00Z","2026-10-19T16:00:00Z",base),
            interval("2026-10-20T08:00:00Z","2026-10-20T16:00:00Z",base),
            interval("2026-10-21T08:00:00Z","2026-10-21T14:00:00Z",
                BioGridEngine.neighbor(base,direction:0)),
            interval("2026-10-22T08:00:00Z","2026-10-22T14:00:00Z",base)
        ]
        let zone=TimeZone(identifier:"Europe/Madrid")!
        let now=date("2026-10-23T14:00:00Z")
        let snapshot=BioGridEngine.simulate(input,now:now,timezone:zone)
        let old=BioGridEngine.simulate(input,now:now,timezone:zone)
        XCTAssertEqual(snapshot.populations,old.populations)

        let born=snapshot.days.reduce(Int64(0)) {
            $0+$1.births.reduce(0,+)
        }
        let dead=snapshot.days.reduce(Int64(0)) {
            $0+$1.deaths.reduce(0,+)
        }
        let survivors=snapshot.populations.values.reduce(Int64(0)) {
            $0+$1.reduce(0,+)
        }
        XCTAssertEqual(survivors,born-dead)
        let outbound=snapshot.cellDays.values.flatMap{$0}
            .reduce(Int64(0)) { $0+$1.departures.flatMap{$0}.reduce(0,+) }
        let inbound=snapshot.cellDays.values.flatMap{$0}
            .reduce(Int64(0)) { $0+$1.arrivals.flatMap{$0}.reduce(0,+) }
        XCTAssertEqual(outbound,inbound)
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try encoder.encode(snapshot.cellDays),
                       try encoder.encode(old.cellDays))
    }

    func testSkirmishesCauseNoAttritionWithoutRivalFamilies() {
        let base=cell(100,100)
        let source=[
            interval("2026-10-19T08:00:00Z","2026-10-19T16:00:00Z",base)
        ]
        let sim=BioGridEngine.simulate(source,
            now:date("2026-10-28T15:00:00Z"))
        XCTAssertEqual(sim.days.reduce(Int64(0)){
            $0+$1.deaths.reduce(0,+)
        },0)
    }
}
