import XCTest
import CoreLocation
@testable import MiMapaDelTiempo

final class VisitTerritoriesV54Tests: XCTestCase {
    private let a = Cell(row: 145254, column: 149255)
    private var b: Cell { Cell(row: a.row, column: a.column + 1) }
    private var c: Cell { Cell(row: a.row, column: a.column + 2) }
    private var isolated: Cell { Cell(row: a.row + 14, column: a.column + 10) }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func slice(_ begin: Date, _ end: Date,
                       _ cell: Cell) -> AssignedInterval {
        AssignedInterval(start: begin, end: end,
            cell: cell, quality: "observado", source: "test")
    }

    func testVisitsCountReturnsNotMinutes() {
        let begin = date("2026-10-19T10:00:00Z")
        let raw = [
            slice(begin, begin.addingTimeInterval(60), a),
            // Tramos del mismo lugar, con pausas GPS, son UNA visita.
            slice(begin.addingTimeInterval(100),
                  begin.addingTimeInterval(200), a),
            slice(begin.addingTimeInterval(200),
                  begin.addingTimeInterval(210), b),
            slice(begin.addingTimeInterval(210),
                  begin.addingTimeInterval(240), a),
            // Horas en la misma visita siguen contando UNA sola vez.
            slice(begin.addingTimeInterval(240),
                  begin.addingTimeInterval(24 * 3600), a)
        ]
        let counted = VisitTerritoryEngine.visitCounts(raw, period: .all)
        XCTAssertEqual(counted[a.id], 2)
        XCTAssertEqual(counted[b.id], 1)
        XCTAssertEqual(counted.values.reduce(0, +), 3)
    }

    func testWindowCountsOverlappingVisitOnceEvenIfItStartedYesterday() {
        let now = date("2026-10-24T12:00:00Z")
        let raw = [
            slice(date("2026-10-23T23:30:00Z"),
                  date("2026-10-24T00:30:00Z"), a),
            slice(date("2026-10-24T01:00:00Z"),
                  date("2026-10-24T01:05:00Z"), b),
            slice(date("2026-10-24T01:10:00Z"),
                  date("2026-10-24T01:20:00Z"), a),
            slice(date("2026-10-10T12:00:00Z"),
                  date("2026-10-10T12:30:00Z"), c)
        ]
        let today = VisitTerritoryEngine.visitCounts(raw, period: .today,
            now: now, calendar: utcCalendar)
        XCTAssertEqual(today[a.id], 2)
        XCTAssertEqual(today[b.id], 1)
        XCTAssertNil(today[c.id])
        let week = VisitTerritoryEngine.visitCounts(raw, period: .week,
            now: now, calendar: utcCalendar)
        XCTAssertEqual(week[a.id], 2)
        XCTAssertNil(week[c.id])
        let month = VisitTerritoryEngine.visitCounts(raw, period: .month,
            now: now, calendar: utcCalendar)
        XCTAssertEqual(month[c.id], 1)
    }

    func testTwoRevisitedNeighborCellsMakeOneCountry() {
        let model = VisitTerritoryEngine.build(counts:
            [a.id: 14, b.id: 3])
        XCTAssertEqual(model.territories.count, 1)
        let country = model.territories[0]
        XCTAssertEqual(country.cells, 2)
        XCTAssertEqual(country.visits, 17)
        XCTAssertEqual(country.peak.id, a.id)
        XCTAssertEqual(country.nuclei, 1)
        XCTAssertEqual(country.periphery, 1)
        XCTAssertTrue(model.tiles.contains {
            $0.id == a.id && $0.classification == .nucleus
        })
        XCTAssertTrue(model.tiles.contains {
            $0.id == b.id && $0.classification == .periphery
        })
    }

    func testOneVisitBridgeDoesNotMergeTwoCountriesAndIsDisputed() {
        let model = VisitTerritoryEngine.build(counts:
            [a.id: 20, b.id: 1, c.id: 8])
        XCTAssertEqual(model.territories.count, 2)
        XCTAssertEqual(model.disputedCount, 1)
        XCTAssertEqual(model.tiles.first(where:{$0.id == b.id})?.classification,
            .disputed)
        XCTAssertNil(model.tiles.first(where:{$0.id == b.id})?.territoryID)
        XCTAssertEqual(model.totalVisits, 29)
    }

    func testSecondVisitOnBridgeMergesBothCountries() {
        let before = VisitTerritoryEngine.build(counts:
            [a.id: 20, b.id: 1, c.id: 8])
        let after = VisitTerritoryEngine.build(counts:
            [a.id: 20, b.id: 2, c.id: 8])
        XCTAssertEqual(before.territories.count, 2)
        XCTAssertEqual(after.territories.count, 1)
        XCTAssertEqual(after.territories[0].cells, 3)
        XCTAssertEqual(after.territories[0].visits, 30)
        XCTAssertEqual(after.disputedCount, 0)
    }

    func testOneVisitFringeIsPeripheryAndIsolatedStaysNeutral() {
        let model = VisitTerritoryEngine.build(counts:
            [a.id: 10, b.id: 1, isolated.id: 1])
        XCTAssertEqual(model.territories.count, 1)
        XCTAssertEqual(model.territories[0].cells, 2)
        XCTAssertEqual(model.tiles.first(where:{$0.id == b.id})?.classification,
            .periphery)
        XCTAssertEqual(model.tiles.first(where:{$0.id == isolated.id})?.classification,
            .neutral)
        XCTAssertEqual(model.counts.count, 3)
    }

    func testNorthSouthNeighborsAreGeographicallyAligned() {
        let madrid = Grid.cell(latitude: 40.4168, longitude: -3.7038)
        let base = Grid.center(madrid)
        for direction in [0, 1] {
            let adjacent = VisitTerritoryEngine.neighbor(madrid,
                direction: direction)
            let target = Grid.center(adjacent)
            let sideways = CLLocation(latitude: base.latitude,
                longitude: base.longitude).distance(from:
                CLLocation(latitude: base.latitude,
                           longitude: target.longitude))
            XCTAssertLessThan(sideways, 51)
            XCTAssertEqual(adjacent.row,
                madrid.row + (direction == 0 ? 1 : -1))
        }
        let north = VisitTerritoryEngine.neighbor(madrid, direction: 0)
        let component = VisitTerritoryEngine.build(counts:
            [madrid.id: 4, north.id: 7])
        XCTAssertEqual(component.territories.count, 1)
    }

    func testSameInputSameBoundariesAndStableColorAssignments() {
        let input = [a.id: 20, b.id: 1, c.id: 8, isolated.id: 5]
        let first = VisitTerritoryEngine.build(counts: input)
        let second = VisitTerritoryEngine.build(counts: input)
        XCTAssertEqual(first.territories.map(\.id),
                       second.territories.map(\.id))
        XCTAssertEqual(first.territories.map(\.colorIndex),
                       second.territories.map(\.colorIndex))
        XCTAssertEqual(first.tiles.map(\.territoryID),
                       second.tiles.map(\.territoryID))
        XCTAssertEqual(first.disputedCount, second.disputedCount)
    }

    func testNoCountryFromOnlyOneVisitCells() {
        let result = VisitTerritoryEngine.build(counts:
            [a.id: 1, b.id: 1, c.id: 1])
        XCTAssertEqual(result.territories.count, 0)
        XCTAssertEqual(result.nucleiCount, 0)
        XCTAssertEqual(result.occupied, 3)
        XCTAssertEqual(result.totalVisits, 3)
    }

    func testManySeparatedVisitClustersRemainDeterministic() {
        // Un historial con numerosos lugares aislados no debe requerir
        // reordenar todo el conjunto restante por cada componente.
        // Saltar tres filas garantiza que los núcleos no se toquen.
        var counts: [String: Int] = [:]
        for index in 0..<600 {
            let cell = Cell(row: a.row + index * 3,
                            column: a.column + 12)
            counts[cell.id] = index.isMultiple(of: 2) ? 2 : 5
        }
        let first = VisitTerritoryEngine.build(counts: counts)
        let second = VisitTerritoryEngine.build(counts: counts)
        XCTAssertEqual(first.territories.count, 600)
        XCTAssertEqual(first.tiles.count, 600)
        // Cada polígono consulta su región al colorear relleno y borde.
        // El índice debe resolver todos los países sin alterar la asignación.
        for region in first.territories {
            XCTAssertEqual(first.region(region.id)?.id, region.id)
            XCTAssertEqual(first.region(region.id)?.visits, region.visits)
        }
        XCTAssertNil(first.region(nil))
        XCTAssertNil(first.region("inexistente"))
        XCTAssertEqual(first.territories.map(\.id),
                       second.territories.map(\.id))
        XCTAssertEqual(first.territories.reduce(0) { $0 + $1.visits },
                       counts.values.reduce(0, +))
    }


    func testIndexedTileLookupAndStableRenderingPriority() {
        var counts: [String: Int] = [:]
        for index in 0..<2300 {
            let cell = Cell(row: a.row + index * 3,
                            column: a.column + 12)
            counts[cell.id] = index + 1
        }
        let snapshot = VisitTerritoryEngine.build(counts: counts)
        XCTAssertEqual(snapshot.tiles.count, 2300)
        XCTAssertEqual(snapshot.renderTiles.count, 2200)
        XCTAssertEqual(snapshot.renderTiles.first?.visits, 2300)
        XCTAssertEqual(snapshot.renderTiles.last?.visits, 101)
        XCTAssertEqual(snapshot.renderTiles.map(\\.visits),
                       Array((101...2300).reversed()))
        for tile in snapshot.tiles {
            XCTAssertEqual(snapshot.tile(tile.id)?.visits, tile.visits)
            XCTAssertEqual(snapshot.tile(tile.id)?.territoryID,
                           tile.territoryID)
        }
        XCTAssertNil(snapshot.tile("cuadricula_inexistente"))
    }

    func testNoMutationsToInputVisitHistoryOrCounts() throws {
        let start = date("2026-10-20T08:00:00Z")
        let visits = [
            slice(start, start.addingTimeInterval(120), a),
            slice(start.addingTimeInterval(120),
                  start.addingTimeInterval(180), b)
        ]
        let original = try JSONEncoder().encode(visits)
        _ = VisitTerritoryEngine.calculate(visits, period: .all)
        XCTAssertEqual(try JSONEncoder().encode(visits), original)
        let counts = [a.id: 10, b.id: 1]
        let copy = counts
        _ = VisitTerritoryEngine.build(counts: counts)
        XCTAssertEqual(counts, copy)
    }
}
