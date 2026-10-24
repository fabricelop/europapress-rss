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

    func testDisputedBorderCountriesAlwaysHaveDifferentColors() {
        // A - disputa de una visita - B: la pertenencia sigue separada,
        // pero nunca deben compartir el mismo color en el mapa político.
        let snapshot = VisitTerritoryEngine.build(counts:
            [a.id: 20, b.id: 1, c.id: 8])
        XCTAssertEqual(snapshot.disputedCount, 1)
        XCTAssertEqual(snapshot.territories.count, 2)
        XCTAssertNotEqual(snapshot.region(a.id)?.colorIndex,
                          snapshot.region(c.id)?.colorIndex)
    }

    func testFourCountriesAroundSharedDisputeUseDifferentColors() {
        // Una cuadrícula visitada una vez puede tocar a cuatro países
        // independientes: todos son vecinos visuales en la frontera.
        let directions = (0..<4).map {
            VisitTerritoryEngine.neighbor(a, direction: $0)
        }
        var visits = [a.id: 1]
        for (index, cell) in directions.enumerated() {
            visits[cell.id] = 7 + index
        }
        let first = VisitTerritoryEngine.build(counts: visits)
        let second = VisitTerritoryEngine.build(counts: visits)
        XCTAssertEqual(first.territories.count, 4)
        XCTAssertEqual(first.disputedCount, 1)
        XCTAssertEqual(Set(first.territories.map(\.colorIndex)).count, 4)
        XCTAssertEqual(first.territories.map(\.colorIndex),
                       second.territories.map(\.colorIndex))
        XCTAssertEqual(first.totalVisits, visits.values.reduce(0,+))
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

    func testOneVisitChainCannotPropagatePeripheryBeyondActiveNeighbor() {
        // Solo la casilla inmediatamente contigua al núcleo puede pasar
        // a periferia: las siguientes visitas aisladas son neutrales.
        let d = Cell(row: a.row, column: a.column + 3)
        let snapshot = VisitTerritoryEngine.build(counts:
            [a.id: 9, b.id: 1, c.id: 1, d.id: 1])
        XCTAssertEqual(snapshot.territories.count, 1)
        XCTAssertEqual(snapshot.territories[0].cells, 2)
        XCTAssertEqual(snapshot.territories[0].visits, 10)
        XCTAssertEqual(snapshot.tile(b.id)?.classification, .periphery)
        XCTAssertEqual(snapshot.tile(b.id)?.territoryID, a.id)
        XCTAssertEqual(snapshot.tile(c.id)?.classification, .neutral)
        XCTAssertNil(snapshot.tile(c.id)?.territoryID)
        XCTAssertEqual(snapshot.tile(d.id)?.classification, .neutral)
        XCTAssertNil(snapshot.tile(d.id)?.territoryID)
    }

    func testOneVisitFringesBetweenCountriesUseOnlyDirectActiveNeighbors() {
        // A(9) - b(1) - c(1) - D(8): cada franja de una visita
        // pertenece a su propio núcleo; ninguna invade la otra.
        let d = Cell(row: a.row, column: a.column + 3)
        let snapshot = VisitTerritoryEngine.build(counts:
            [a.id: 9, b.id: 1, c.id: 1, d.id: 8])
        XCTAssertEqual(snapshot.territories.count, 2)
        XCTAssertEqual(snapshot.disputedCount, 0)
        XCTAssertEqual(snapshot.tile(b.id)?.classification, .periphery)
        XCTAssertEqual(snapshot.tile(c.id)?.classification, .periphery)
        XCTAssertEqual(snapshot.tile(b.id)?.territoryID, a.id)
        XCTAssertEqual(snapshot.tile(c.id)?.territoryID, d.id)
        XCTAssertEqual(snapshot.totalVisits, 19)
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
        XCTAssertEqual(snapshot.renderTiles.map(\.visits),
                       Array((101...2300).reversed()))
        for tile in snapshot.tiles {
            XCTAssertEqual(snapshot.tile(tile.id)?.visits, tile.visits)
            XCTAssertEqual(snapshot.tile(tile.id)?.territoryID,
                           tile.territoryID)
        }
        XCTAssertNil(snapshot.tile("cuadricula_inexistente"))
    }

    func testViewportRendersNearbyLowVisitCellsBeyondGlobalLimit() {
        // 2300 países alejados entre sí. Una casilla de una visita,
        // fuera del top global, debe aparecer al acercar el mapa a ella.
        var counts: [String: Int] = [:]
        for index in 0..<2300 {
            let cell = Cell(row: a.row + index * 3,
                            column: a.column + 12)
            counts[cell.id] = index + 2
        }
        let local = Cell(row: a.row - 30, column: a.column)
        counts[local.id] = 1
        let snapshot = VisitTerritoryEngine.build(counts: counts)
        XCTAssertEqual(snapshot.renderTiles.count, 2200)
        XCTAssertFalse(snapshot.renderTiles.contains { $0.id == local.id })

        let point = Grid.center(local)
        let visible = snapshot.renderTiles(
            near: point.latitude, longitude: point.longitude,
            latitudeDelta: 0.004, longitudeDelta: 0.004)
        XCTAssertTrue(visible.contains { $0.id == local.id })
        XCTAssertFalse(visible.contains { $0.visits == 2301 })
        XCTAssertEqual(visible.map(\.id), snapshot.renderTiles(
            near: point.latitude, longitude: point.longitude,
            latitudeDelta: 0.004, longitudeDelta: 0.004).map(\.id))
        XCTAssertTrue(snapshot.renderTiles(
            near: point.latitude, longitude: point.longitude,
            latitudeDelta: 0.004, longitudeDelta: 0.004,
            limit: 0).isEmpty)
    }

    func testSpatialViewportIndexMatchesFullScanAtDifferentZooms() {
        // La optimización espacial no puede cambiar ni una casilla ni su
        // prioridad de dibujo, incluso con empates y límites pequeños.
        var counts: [String: Int] = [:]
        for row in 0..<75 {
            for column in 0..<45 {
                let cell = Cell(row: a.row + row, column: a.column + column)
                counts[cell.id] = 1 + (row * 17 + column * 23) % 21
            }
        }
        let snapshot = VisitTerritoryEngine.build(counts: counts)
        XCTAssertEqual(snapshot.tiles.count, 3375)
        let byPriority = snapshot.tiles.sorted {
            $0.visits == $1.visits ? $0.id < $1.id : $0.visits > $1.visits
        }

        for (row, column, latDelta, lonDelta, limit) in [
            (4, 3, 0.004, 0.004, 7),
            (38, 21, 0.016, 0.018, 50),
            (70, 42, 0.010, 0.012, 2200),
            (38, 21, 0.3, 0.3, 100)
        ] {
            let center = Grid.center(Cell(row: a.row + row,
                                          column: a.column + column))
            let expected = Array(byPriority.filter { tile in
                let point = Grid.center(tile.cell)
                return abs(point.latitude - center.latitude) <= latDelta * 0.75
                    && abs(point.longitude - center.longitude) <= lonDelta * 0.75
            }.prefix(limit)).map(\.id)
            let actual = snapshot.renderTiles(
                near: center.latitude, longitude: center.longitude,
                latitudeDelta: latDelta, longitudeDelta: lonDelta,
                limit: limit).map(\.id)
            XCTAssertEqual(actual, expected,
                "La vista espacial no coincide en zoom \(latDelta), \(lonDelta)")
        }
    }

    func testNoMutationsToInputVisitHistoryOrCounts() throws {
        let start = date("2026-10-20T08:00:00Z")
        let visits = [
            slice(start, start.addingTimeInterval(120), a),
            slice(start.addingTimeInterval(120),
                  start.addingTimeInterval(180), b)
        ]
        // JSONEncoder no garantiza el orden de claves por defecto: dos
        // codificaciones del MISMO objeto pueden diferir en bytes.
        // Orden estable para comprobar que el motor no modifica el historial.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(visits)
        _ = VisitTerritoryEngine.calculate(visits, period: .all)
        XCTAssertEqual(try encoder.encode(visits), original)
        let counts = [a.id: 10, b.id: 1]
        let copy = counts
        _ = VisitTerritoryEngine.build(counts: counts)
        XCTAssertEqual(counts, copy)
    }
}
