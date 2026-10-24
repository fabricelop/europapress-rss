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

struct TimeZoneOverlay: Identifiable {
    let zone:TimeCustomZone
    let contours:[TimeZoneBorderPath]
    let center:CLLocationCoordinate2D?
    var id:UUID { zone.id }
}

struct TimeZoneBorderPath:Identifiable {
    let id:Int
    let coordinates:[CLLocationCoordinate2D]
}

struct TimeZoneBorderSegment {
    var start: CLLocationCoordinate2D
    var end: CLLocationCoordinate2D
}

/// El contorno exacto de la selección se calcula una sola vez por zona.
/// Se unen lados adyacentes en líneas continuas para crear muy pocas
/// superposiciones MapPolyline, incluso en zonas de miles de casillas.
enum TimeZoneOutline {
    static func segments(for zone:TimeCustomZone,maxCells:Int = TimeZoneGeometry.maximumCells) -> [TimeZoneBorderSegment] {
        let ids=zone.cells
        var boundary:[TimeZoneBorderSegment]=[]
        for id in zone.cellIDs.prefix(maxCells) {
            guard let cell=TimeAnalytics.cell(id) else { continue }
            let vertices=Grid.polygon(cell)
            let middle=Grid.center(cell)
            for i in 0..<4 {
                let a=vertices[i],b=vertices[(i+1)%4]
                let midpoint=CLLocationCoordinate2D(
                    latitude:(a.latitude+b.latitude)/2,
                    longitude:(a.longitude+b.longitude)/2)
                let outside=CLLocationCoordinate2D(
                    latitude:midpoint.latitude+(midpoint.latitude-middle.latitude)*0.04,
                    longitude:midpoint.longitude+(midpoint.longitude-middle.longitude)*0.04)
                let neighbour=Grid.cell(latitude:outside.latitude,longitude:outside.longitude)
                if !ids.contains(neighbour.id) {
                    boundary.append(TimeZoneBorderSegment(start:a,end:b))
                }
            }
        }
        return boundary
    }

    /// Coordenadas vecinas de filas métricas diferentes pueden diferir
    /// ligeramente en longitud. Clave a ~10 m, frente a celdas de ~100 m.
    private struct Vertex:Hashable {
        let lat:Int
        let lon:Int
        init(_ coordinate:CLLocationCoordinate2D) {
            lat=Int((coordinate.latitude*10000).rounded())
            lon=Int((coordinate.longitude*10000).rounded())
        }
    }

    static func contours(for zone:TimeCustomZone) -> [TimeZoneBorderPath] {
        let edges=segments(for:zone)
        guard !edges.isEmpty else { return [] }
        var adjacency:[Vertex:[Int]] = [:]
        for (i,e) in edges.enumerated() {
            adjacency[Vertex(e.start),default:[]].append(i)
            adjacency[Vertex(e.end),default:[]].append(i)
        }
        var seen=Set<Int>()
        var paths:[TimeZoneBorderPath]=[]
        // Unimos todos los lados conexos en vez de dibujar cada uno por separado.
        // No se simplifican las posiciones de los puntos GPS ni el perímetro real.
        for initial in edges.indices where !seen.contains(initial) {
            var coordinates=[edges[initial].start,edges[initial].end]
            seen.insert(initial)
            var current=Vertex(edges[initial].end)
            let origin=Vertex(edges[initial].start)
            while seen.count < edges.count {
                if current == origin { break }
                guard let next=adjacency[current]?.first(where:{!seen.contains($0)}) else { break }
                seen.insert(next)
                let edge=edges[next]
                let point = Vertex(edge.start)==current ? edge.end : edge.start
                coordinates.append(point)
                current=Vertex(point)
            }
            if coordinates.count>=2 {
                paths.append(TimeZoneBorderPath(id:paths.count,coordinates:coordinates))
            }
        }
        return paths
    }

    /// Compatibilidad de las pruebas antiguas: ahora devuelve también la forma
    /// exacta y no un rectángulo exterior.
    static func renderSegments(for zone:TimeCustomZone) -> [TimeZoneBorderSegment] {
        segments(for:zone)
    }

    static func visibleCenter(for zone:TimeCustomZone) -> CLLocationCoordinate2D? {
        let coords=zone.cellIDs.compactMap(TimeAnalytics.cell).map(Grid.center)
        guard !coords.isEmpty else { return nil }
        return CLLocationCoordinate2D(
            latitude:coords.map(\.latitude).reduce(0,+)/Double(coords.count),
            longitude:coords.map(\.longitude).reduce(0,+)/Double(coords.count))
    }
}


/// Compact, presentation-only map badges for named zones. Never changes
/// the saved name or the zone's cell geometry and GPS records.
enum TimeZoneLabelText {
    static func initials(_ title:String) -> String {
        let ignored:Set<String>=["de","del","la","las","los","el","en","y","a"]
        let words=title.split(whereSeparator:{ !$0.isLetter && !$0.isNumber })
                       .map(String.init)
        let important=words.filter { !ignored.contains($0.lowercased()) }
        let chosen=important.isEmpty ? words : important
        let letters=chosen.prefix(4).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased().isEmpty ? "Z" : letters.joined().uppercased()
    }
}
