import XCTest
@testable import MiMapaDelTiempo

final class BioGridV52BlockadeExodusTests: XCTestCase {
    private let zone = TimeZone(identifier:"Europe/Madrid")!

    private func date(_ iso:String)->Date {
        ISO8601DateFormatter().date(from:iso)!
    }

    private func interval(_ start:String,_ end:String,_ cell:Cell)->AssignedInterval {
        AssignedInterval(start:date(start),end:date(end),
                         cell:cell,quality:"confirmed",source:"test")
    }

    private let origin=Cell(row:145254,column:149255)

    /// Primero 9 L (lunes) y luego 9 M (martes).
    /// Nadie puede emigrar normalmente: menos de 10 bacterias por familia.
    /// Tras cinco noches completas de convivencia, M (2a en empate)
    /// tiene que emigrar íntegra, sin pérdida de materia.
    private var balanced:[AssignedInterval] {
        [
            interval("2026-10-19T08:00:00Z","2026-10-19T08:45:00Z",origin),
            interval("2026-10-20T08:00:00Z","2026-10-20T08:45:00Z",origin)
        ]
    }

    private func simulation(_ dateISO:String)->BioGridSnapshot {
        BioGridEngine.simulate(balanced,now:date(dateISO),timezone:zone)
    }

    func testBlockadeRequiresFiveConsecutiveNightsAndTwoFamilies() {
        let pair:[Int64]=[9,9,0,0,0,0,0]
        XCTAssertEqual(BioGridEngine.nextBlockadeDays(0,counts:pair,outgoing:0),1)
        XCTAssertEqual(BioGridEngine.nextBlockadeDays(3,counts:pair,outgoing:0),4)
        XCTAssertEqual(BioGridEngine.nextBlockadeDays(4,counts:pair,outgoing:0),5)
        XCTAssertEqual(BioGridEngine.nextBlockadeDays(5,counts:pair,outgoing:0),5)
        XCTAssertEqual(BioGridEngine.nextBlockadeDays(4,counts:pair,outgoing:1),0)
        XCTAssertEqual(BioGridEngine.nextBlockadeDays(4,
            counts:[9,0,0,0,0,0,0],outgoing:0),0)
        XCTAssertEqual(BioGridEngine.nextBlockadeDays(0,
            counts:[0,0,0,0,0,0,0],outgoing:0),0)
    }

    func testSecondStrongestNeverDominantAndTieKeepsPersistentLeader() {
        XCTAssertEqual(BioGridEngine.exodusFamily([9,9,0,0,0,0,0],
            priorDominant:0),1)
        XCTAssertEqual(BioGridEngine.exodusFamily([9,9,0,0,0,0,0],
            priorDominant:1),0)
        XCTAssertEqual(BioGridEngine.exodusFamily([10,40,25,0,0,0,0],
            priorDominant:1),2)
        XCTAssertNil(BioGridEngine.exodusFamily([10,0,0,0,0,0,0],
            priorDominant:0))
    }

    func testDestinationIsLeastPopulatedOfFourAdjacentCells() {
        let source=Cell(row:10,column:20)
        let north=BioGridEngine.neighbor(source,direction:0)
        let south=BioGridEngine.neighbor(source,direction:1)
        let east=BioGridEngine.neighbor(source,direction:2)
        let west=BioGridEngine.neighbor(source,direction:3)
        var occupants:[String:[Int64]]=[
            north.id:[100,0,0,0,0,0,0],
            south.id:[20,0,0,0,0,0,0],
            east.id:[5,0,0,0,0,0,0],
            west.id:[10,0,0,0,0,0,0]
        ]
        XCTAssertEqual(BioGridEngine.exodusDestination(cell:source,
            populations:occupants),2)
        occupants[east.id]=[20,0,0,0,0,0,0]
        XCTAssertEqual(BioGridEngine.exodusDestination(cell:source,
            populations:occupants),3)
        occupants[west.id]=[20,0,0,0,0,0,0]
        XCTAssertEqual(BioGridEngine.exodusDestination(cell:source,
            populations:occupants),1)
        occupants=[:]
        // Empate vacío N, S, E, O -> norte, sin diagonal.
        XCTAssertEqual(BioGridEngine.exodusDestination(cell:source,
            populations:occupants),0)
    }

    func testExodusOccursExactlyAtFifthNightAndMovesEntireRunnerUp() {
        let fourth=simulation("2026-10-24T12:00:00Z")
        XCTAssertTrue(fourth.exodusEvents.isEmpty)
        let fifth=simulation("2026-10-25T12:00:00Z")
        XCTAssertEqual(fifth.exodusEvents.count,1)
        guard let event=fifth.exodusEvents.first else { return }
        let north=BioGridEngine.neighbor(origin,direction:0)
        XCTAssertEqual(event.source,origin.id)
        XCTAssertEqual(event.destination,north.id)
        XCTAssertEqual(event.family,1)
        XCTAssertEqual(event.amount,9)
        var localCalendar = Calendar(identifier:.gregorian)
        localCalendar.timeZone = zone
        XCTAssertEqual(event.date,localCalendar.startOfDay(
            for:date("2026-10-25T12:00:00Z")))

        let departure=fifth.cellDays[origin.id]?.first {
            $0.date==event.date
        }
        let arrival=fifth.cellDays[north.id]?.first {
            $0.date==event.date
        }
        XCTAssertEqual(departure?.departures[1][0],9)
        XCTAssertEqual(arrival?.arrivals[1][1],9)
        XCTAssertEqual(fifth.populations[origin.id]?[0],9)
        XCTAssertEqual(fifth.populations[origin.id]?[1],0)
        XCTAssertEqual(fifth.populations[north.id]?[1],9)
        XCTAssertEqual(fifth.days.reduce(Int64(0)) {
            $0+$1.migrated.reduce(0,+)
        },9)
        XCTAssertEqual(fifth.populations.values.reduce(Int64(0)) {
            $0+$1.reduce(0,+)
        },18)
    }

    func testFullExodusDoesNotRepeatNextNightAndAllLedgersConservePopulation() throws {
        let snapshot=simulation("2026-10-29T13:00:00Z")
        XCTAssertEqual(snapshot.exodusEvents.count,1)
        for (key, records) in snapshot.cellDays {
            let history=snapshot.cellHistory[key] ?? []
            for record in records {
                let before=history.last(where:{$0.date<record.date})?.counts ??
                    Array(repeating:Int64(0),count:7)
                let after=history.last(where:{$0.date<=record.date})?.counts ??
                    Array(repeating:Int64(0),count:7)
                for family in 0..<7 {
                    XCTAssertEqual(after[family],before[family]+record.delta(family),
                        "Incorrect cell ledger \(key) on \(record.date)")
                }
            }
        }
        let allRecords=snapshot.cellDays.values.flatMap{$0}
        let incoming=allRecords.reduce(Int64(0)) {
            $0+$1.arrivals.flatMap{$0}.reduce(0,+)
        }
        let outgoing=allRecords.reduce(Int64(0)) {
            $0+$1.departures.flatMap{$0}.reduce(0,+)
        }
        XCTAssertEqual(incoming,outgoing)

        let another=simulation("2026-10-29T13:00:00Z")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try encoder.encode(snapshot.exodusEvents),
                       try encoder.encode(another.exodusEvents))
        XCTAssertEqual(try encoder.encode(snapshot.cellDays),
                       try encoder.encode(another.cellDays))
    }
}
