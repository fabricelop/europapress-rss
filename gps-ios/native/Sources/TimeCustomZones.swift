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
    /// Selección determinista si una cuadrícula pertenece a varias zonas:
    /// primero la zona más pequeña, después nombre e identificador. Nunca
    /// modifica nombres ni tiempos almacenados.
    static func primary(for cellID:String, zones:[TimeCustomZone]) -> TimeCustomZone? {
        zones.filter { $0.cells.contains(cellID) }.sorted {
            if $0.cells.count != $1.cells.count { return $0.cells.count < $1.cells.count }
            let compare=$0.name.localizedStandardCompare($1.name)
            if compare != .orderedSame { return compare == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }.first
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

struct TimeZoneBorderSegment {
    var start: CLLocationCoordinate2D
    var end: CLLocationCoordinate2D
}

/// Delimitación de la zona sin dibujar líneas internas entre sus cuadrículas.
/// Los vértices provienen de Grid.polygon; son aptos para mapa online y offline.
enum TimeZoneOutline {
    static func segments(for zone:TimeCustomZone, maxCells:Int = 600) -> [TimeZoneBorderSegment] {
        let ids=zone.cells
        var segments:[TimeZoneBorderSegment]=[]
        for id in zone.cellIDs.prefix(maxCells) {
            guard let cell=TimeAnalytics.cell(id) else { continue }
            let vertices=Grid.polygon(cell)
            for i in 0..<4 {
                let a=vertices[i],b=vertices[(i+1)%4]
                let center=CLLocationCoordinate2D(
                    latitude:(a.latitude+b.latitude)/2,
                    longitude:(a.longitude+b.longitude)/2)
                // Coordenada 1.5 metros fuera de la casilla en dirección
                // opuesta al centro: comprueba un vecino sin asumir columnas
                // iguales en distintas latitudes.
                let middle=Grid.center(cell)
                let outside=CLLocationCoordinate2D(
                    latitude:center.latitude+(center.latitude-middle.latitude)*0.04,
                    longitude:center.longitude+(center.longitude-middle.longitude)*0.04)
                let neighbor=Grid.cell(latitude:outside.latitude,longitude:outside.longitude)
                if !ids.contains(neighbor.id) {
                    segments.append(TimeZoneBorderSegment(start:a,end:b))
                }
            }
        }
        return segments
    }
    /// Más de 80 cuadrículas: usar solo el recuadro exterior en vez de generar
    /// cientos de MapPolyline en cada cambio GPS. La geometría real se guarda
    /// intacta, esta simplificación afecta SOLO al dibujo.
    static func renderSegments(for zone:TimeCustomZone) -> [TimeZoneBorderSegment] {
        guard zone.cellIDs.count > 80 else { return segments(for:zone,maxCells:80) }
        let points=zone.cellIDs.compactMap(TimeAnalytics.cell).flatMap(Grid.polygon)
        guard let minLat=points.map(\.latitude).min(),
              let maxLat=points.map(\.latitude).max(),
              let minLon=points.map(\.longitude).min(),
              let maxLon=points.map(\.longitude).max() else { return [] }
        let a=CLLocationCoordinate2D(latitude:minLat,longitude:minLon)
        let b=CLLocationCoordinate2D(latitude:minLat,longitude:maxLon)
        let c=CLLocationCoordinate2D(latitude:maxLat,longitude:maxLon)
        let d=CLLocationCoordinate2D(latitude:maxLat,longitude:minLon)
        return [(a,b),(b,c),(c,d),(d,a)].map {
            TimeZoneBorderSegment(start:$0.0,end:$0.1)
        }
    }

    static func visibleCenter(for zone:TimeCustomZone) -> CLLocationCoordinate2D? {
        let coords=zone.cellIDs.compactMap(TimeAnalytics.cell).map(Grid.center)
        guard !coords.isEmpty else { return nil }
        return CLLocationCoordinate2D(
            latitude:coords.map(\.latitude).reduce(0,+)/Double(coords.count),
            longitude:coords.map(\.longitude).reduce(0,+)/Double(coords.count))
    }
}
