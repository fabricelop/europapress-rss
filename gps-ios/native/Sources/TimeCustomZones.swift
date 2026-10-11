import Foundation
import CoreLocation

/// Las zonas son conjuntos de cuadrículas completas. El trazo es únicamente
/// una herramienta para seleccionar sus centros, no una nueva fuente de tiempo.
struct TimeCustomZone: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var cellIDs: [String]
    var createdAt: Date = .now
    var cells: Set<String> { Set(cellIDs) }
}

enum TimeZoneCatalog {
    /// Los lugares de versiones anteriores se muestran como zonas, sin
    /// duplicar sus identificadores ni reescribir su historial.
    static func visible(custom:[TimeCustomZone], legacy:[UserPlace]) -> [TimeCustomZone] {
        let ids=Set(custom.map(\.id))
        let previous=legacy.filter { !ids.contains($0.id) }
            .map { TimeCustomZone(id:$0.id,name:$0.name,
                                  cellIDs:$0.cellIDs,createdAt:.distantPast) }
        return (custom + previous).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

enum TimeZoneGeometry {
    static let maximumCells = 3_000
    static func contains(_ point: CLLocationCoordinate2D, in polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        let x = point.longitude, y = point.latitude
        var inside = false
        for i in polygon.indices {
            let j = (i + polygon.count - 1) % polygon.count
            let a = polygon[i], b = polygon[j]
            if (a.latitude > y) != (b.latitude > y) {
                let crossing = (b.longitude - a.longitude) * (y - a.latitude) /
                               (b.latitude - a.latitude) + a.longitude
                if x < crossing { inside.toggle() }
            }
        }
        return inside
    }

    /// Incluye casillas aún no visitadas, para que el tiempo futuro cuente.
    /// Rechaza trazos demasiado grandes antes de reservar miles de cuadrículas.
    static func selectedCells(inside polygon: [CLLocationCoordinate2D]) -> Set<String> {
        guard polygon.count >= 3 else { return [] }
        let lats = polygon.map(\.latitude), lons = polygon.map(\.longitude)
        guard let south = lats.min(), let north = lats.max(),
              let west = lons.min(), let east = lons.max(),
              north - south < 1, east - west < 1 else { return [] }
        let rowA = Grid.cell(latitude:south,longitude:west).row
        let rowB = Grid.cell(latitude:north,longitude:east).row
        guard rowB >= rowA, rowB-rowA <= 350 else { return [] }
        var selected: Set<String> = []
        var checked = 0
        for row in rowA...rowB {
            let latitude = Grid.center(Cell(row:row,column:0)).latitude
            let colA = Grid.cell(latitude:latitude,longitude:west).column
            let colB = Grid.cell(latitude:latitude,longitude:east).column
            guard colB >= colA, colB-colA <= 350 else { return [] }
            checked += colB-colA+1
            guard checked <= maximumCells * 4 else { return [] }
            for col in colA...colB {
                let cell = Cell(row:row,column:col)
                if contains(Grid.center(cell),in:polygon) {
                    selected.insert(cell.id)
                    if selected.count > maximumCells { return [] }
                }
            }
        }
        return selected
    }
}
