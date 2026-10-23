import Foundation

/// Motor independiente de BIOGRID: solo LEE visitas del historial GPS.
/// No muta intervalos, zonas, ubicaciones ni estados de otras simulaciones.
enum VisitTerritoryPeriod: String, CaseIterable, Identifiable {
    case today, week, month, quarter, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Hoy"
        case .week: return "7 días"
        case .month: return "30 días"
        case .quarter: return "90 días"
        case .all: return "Todo"
        }
    }

    func window(ending now: Date, calendar: Calendar) -> DateInterval? {
        let start: Date
        switch self {
        case .all: return nil
        case .today:
            start = calendar.startOfDay(for: now)
        case .week:
            start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month:
            start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .quarter:
            start = calendar.date(byAdding: .day, value: -90, to: now) ?? now
        }
        return DateInterval(start: start, end: now)
    }
}

enum VisitTerritoryCellClass: String {
    case nucleus, periphery, disputed, neutral
}

struct VisitTerritoryCell: Identifiable {
    let cell: Cell
    let visits: Int
    let territoryID: String?
    let classification: VisitTerritoryCellClass
    let frontier: Bool
    var id: String { cell.id }
}

struct VisitTerritoryRegion: Identifiable {
    /// El identificador es la cuadrícula con más visitas de esta región.
    /// No depende del orden de los diccionarios ni de un hash aleatorio.
    let id: String
    let peak: Cell
    let peakVisits: Int
    let visits: Int
    let cells: Int
    let nuclei: Int
    let periphery: Int
    let frontiers: Int
    let colorIndex: Int
}

struct VisitTerritorySnapshot {
    let period: VisitTerritoryPeriod
    let counts: [String: Int]
    let tiles: [VisitTerritoryCell]
    let territories: [VisitTerritoryRegion]

    var disputedCount: Int {
        tiles.filter { $0.classification == .disputed }.count
    }
    var nucleiCount: Int {
        tiles.filter { $0.classification == .nucleus }.count
    }
    var totalVisits: Int { counts.values.reduce(0, +) }
    var occupied: Int { counts.count }

    func region(_ id: String?) -> VisitTerritoryRegion? {
        guard let id else { return nil }
        return territories.first(where: { $0.id == id })
    }
}

/// Clustering espacial determinista en cuadrículas de ~100 m.
///
/// 1. Dos visitas o más => casilla activa.
/// 2. Las casillas activas conectadas por lados forman un país.
/// 3. Una visita => periferia si toca un solo país; disputada si toca >=2.
/// 4. Las visitas aisladas de una sola vez permanecen neutrales.
/// 5. El máximo de visitas del país es su núcleo representativo.
///
/// Ni un cronómetro ni el número de minutos afectan a las fronteras.
enum VisitTerritoryEngine {
    static let minimumActiveVisits = 2
    static let strongNucleusVisits = 5

    /// Misma semántica que el contador del mapa: cambiar de cuadrícula
    /// inicia una nueva visita al regresar, aunque el intervalo se fragmentó
    /// por el GPS. Una pausa en la misma casilla no crea entradas ficticias.
    ///
    /// El filtro temporal incluye una visita iniciada antes de la ventana
    /// si su estancia confirmada se solapa con ella.
    static func visitCounts(_ raw: [AssignedInterval],
                            period: VisitTerritoryPeriod,
                            now: Date = .now,
                            calendar: Calendar = .current) -> [String: Int] {
        let window = period.window(ending: now, calendar: calendar)
        let segments = TimeAttribution.canonical(raw)
        var totals: [String: Int] = [:]
        var lastID: String?
        var runStart: Date?
        var runEnd: Date?

        func closeRun() {
            guard let key = lastID, let begin = runStart,
                  let end = runEnd, end > begin else { return }
            if let window {
                guard begin < window.end, end > window.start else { return }
            }
            totals[key, default: 0] += 1
        }

        for item in segments where item.end > item.start {
            let key = item.cell.id
            if key == lastID {
                runEnd = max(runEnd ?? item.end, item.end)
            } else {
                closeRun()
                lastID = key
                runStart = item.start
                runEnd = item.end
            }
        }
        closeRun()
        return totals
    }

    /// Vecindad CARDINAL GEOGRÁFICA, no por columna fija: la escala de
    /// longitud de Grid cambia al pasar a otra fila. Esto evita el error de
    /// Norte/Sur ya corregido anteriormente en BIOGRID.
    static func neighbor(_ cell: Cell, direction: Int) -> Cell {
        switch direction {
        case 0, 1:
            let origin = Grid.center(cell)
            let offset = direction == 0 ? Grid.latitudeStep : -Grid.latitudeStep
            return Grid.cell(latitude: origin.latitude + offset,
                             longitude: origin.longitude)
        case 2: return Cell(row: cell.row, column: cell.column + 1)
        default: return Cell(row: cell.row, column: cell.column - 1)
        }
    }

    static func neighbors(_ cell: Cell) -> [Cell] {
        (0..<4).map { neighbor(cell, direction: $0) }
    }

    private static func colorIndex(_ id: String) -> Int {
        let values = id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return Int(values % 8)
    }

    /// Constructor separado del GPS para permitir pruebas exactas de
    /// agrupación, frontera, fusión y sensibilidad al nº de visitas.
    static func build(counts: [String: Int],
                      period: VisitTerritoryPeriod = .all) -> VisitTerritorySnapshot {
        let valid = counts.filter { $0.value > 0 && TimeAnalytics.cell($0.key) != nil }
        let eligible = Set(valid.filter { $0.value >= minimumActiveVisits }.keys)
        var pending = eligible
        var ownership: [String: String] = [:]
        var components: [String: [String]] = [:]
        var peaks: [String: Cell] = [:]

        // Ordenar UNA vez. Ordenar todo el conjunto pendiente en cada
        // componente era cuadrático para miles de visitas aisladas (viajes,
        // paseos), y podía bloquear el mapa incluso fuera del hilo principal.
        // Se mantiene exactamente el mismo orden y resultado determinista.
        for begin in eligible.sorted() {
            guard pending.remove(begin) != nil else { continue }
            var queue = [begin]
            var index = 0
            var members: [String] = []
            while index < queue.count {
                let id = queue[index]; index += 1
                members.append(id)
                guard let cell = TimeAnalytics.cell(id) else { continue }
                for other in neighbors(cell) where pending.contains(other.id) {
                    pending.remove(other.id)
                    queue.append(other.id)
                }
            }

            let peakKey = members.sorted {
                let a = valid[$0] ?? 0, b = valid[$1] ?? 0
                return a == b ? $0 < $1 : a > b
            }[0]
            guard let peak = TimeAnalytics.cell(peakKey) else { continue }
            peaks[peakKey] = peak
            components[peakKey] = members
            for id in members { ownership[id] = peakKey }
        }

        var category: [String: VisitTerritoryCellClass] = [:]
        for (key, owner) in ownership {
            let count = valid[key] ?? 0
            category[key] = count >= strongNucleusVisits || key == owner
                ? .nucleus : .periphery
        }

        // Casillas visitadas una vez no fusionan dos países. Una sola
        // visita puede producir periferia, nunca un corredor de fusión.
        for key in valid.keys.sorted() where ownership[key] == nil {
            guard let cell = TimeAnalytics.cell(key) else { continue }
            let touching = Set(neighbors(cell).compactMap { ownership[$0.id] })
            if touching.count == 1, let only = touching.first {
                ownership[key] = only
                components[only, default: []].append(key)
                category[key] = .periphery
            } else if touching.count > 1 {
                category[key] = .disputed
            } else {
                category[key] = .neutral
            }
        }

        // Toda región solo tiene sus propias casillas; la frontera es
        // la casilla que linda con neutral/disputada/otro país.
        var regionBorders: [String: Int] = [:]
        let tiles: [VisitTerritoryCell] = valid.keys.sorted().compactMap { key in
            guard let cell = TimeAnalytics.cell(key) else { return nil }
            let owner = ownership[key]
            let onFrontier = owner != nil && neighbors(cell).contains {
                ownership[$0.id] != owner
            }
            if onFrontier, let owner {
                regionBorders[owner, default: 0] += 1
            }
            return VisitTerritoryCell(cell: cell, visits: valid[key] ?? 0,
                territoryID: owner, classification: category[key] ?? .neutral,
                frontier: onFrontier)
        }

        let regions = components.compactMap { id, ids -> VisitTerritoryRegion? in
            guard let peak = peaks[id] else { return nil }
            let nuclei = ids.filter { category[$0] == .nucleus }.count
            let periphery = ids.filter { category[$0] == .periphery }.count
            return VisitTerritoryRegion(id: id, peak: peak,
                peakVisits: valid[id] ?? 0,
                visits: ids.reduce(0) { $0 + (valid[$1] ?? 0) },
                cells: ids.count, nuclei: nuclei, periphery: periphery,
                frontiers: regionBorders[id] ?? 0,
                colorIndex: colorIndex(id))
        }.sorted {
            $0.visits == $1.visits ? $0.id < $1.id : $0.visits > $1.visits
        }

        return VisitTerritorySnapshot(period: period,
            counts: valid, tiles: tiles, territories: regions)
    }

    static func calculate(_ raw: [AssignedInterval],
                          period: VisitTerritoryPeriod = .all,
                          now: Date = .now,
                          calendar: Calendar = .current) -> VisitTerritorySnapshot {
        build(counts: visitCounts(raw, period: period, now: now, calendar: calendar),
              period: period)
    }
}
