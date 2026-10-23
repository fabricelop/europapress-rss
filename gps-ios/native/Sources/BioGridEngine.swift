import Foundation

// Simulador determinista. No modifica el historial GPS ni necesita red.
struct BioGridDay: Codable, Identifiable {
    let date: Date
    var births = [Int64](repeating: 0, count: 7)
    var migrated = [Int64](repeating: 0, count: 7)
    var deaths = [Int64](repeating: 0, count: 7)
    var newCells = [Int64](repeating: 0, count: 7)
    var conquests = [Int64](repeating: 0, count: 7)
    var id: Date { date }
}

/// Actividad de UNA cuadrícula durante UNA jornada local de Madrid.
/// Llegan/salen/mueren = ciclo de medianoche que inicia la fecha indicada.
/// Nacen = bloques de cinco minutos completados durante esa misma fecha.
/// Matrices por familia L M X J V S D y dirección N S E O, relativas a la cuadrícula.
struct BioGridCellDay: Codable, Identifiable {
    let date: Date
    var births = [Int64](repeating: 0, count: 7)
    var arrivals = Array(repeating: [Int64](repeating: 0, count: 4), count: 7)
    var departures = Array(repeating: [Int64](repeating: 0, count: 4), count: 7)
    var deaths = [Int64](repeating: 0, count: 7)
    var id: Date { date }

    func arrived(_ family: Int) -> Int64 { arrivals[family].reduce(0,+) }
    func departed(_ family: Int) -> Int64 { departures[family].reduce(0,+) }
    func delta(_ family: Int) -> Int64 {
        births[family] + arrived(family) - departed(family) - deaths[family]
    }
    var hasActivity: Bool {
        births.contains(where: { $0 != 0 }) ||
        deaths.contains(where: { $0 != 0 }) ||
        arrivals.contains(where: { $0.contains(where: { $0 != 0 }) }) ||
        departures.contains(where: { $0.contains(where: { $0 != 0 }) })
    }
}

struct BioGridHistoryPoint: Codable, Identifiable {
    let date: Date
    let population: [Int64]
    let territory: [Int]
    var id: Date { date }
}

struct BioGridCellPoint: Codable {
    let date: Date
    let counts: [Int64]
}

struct BioGridTerritoryEvent: Codable, Identifiable {
    enum Kind: String, Codable {
        case first, conquest, recolonization
    }
    let date: Date
    let cellKey: String
    let family: Int
    let previousFamily: Int?
    let kind: Kind
    var id: String { "\(date.timeIntervalSince1970)|\(cellKey)|\(kind.rawValue)|\(family)" }
}

struct BioGridSnapshot: Codable {
    var populations: [String: [Int64]] = [:]
    var days: [BioGridDay] = []
    var latestProcessed: Date?
    var sourceFingerprint: String = ""
    // Datos calculados: nunca se escribe en los intervalos GPS originales.
    var todayBirths: [String: [Int64]] = [:]
    var remainingSeconds: [String: Double] = [:]
    var lastIntervalEnds: [String: Date] = [:]
    var historical: [BioGridHistoryPoint] = []
    var cellHistory: [String: [BioGridCellPoint]] = [:]
    var cellDays: [String: [BioGridCellDay]] = [:]
    var territoryEvents: [BioGridTerritoryEvent] = []
    var rulers: [String: Int] = [:]

    func ranking() -> [(family: Int, population: Int64, territory: Int)] {
        var population = [Int64](repeating: 0, count: 7)
        var territory = [Int](repeating: 0, count: 7)
        for (key, counts) in populations {
            guard let maxCount = counts.max(), maxCount > 0 else { continue }
            for i in 0..<7 { population[i] += counts[i] }
            // Solo los empates sin dominante persistido usan este orden fijo.
            let winner = rulers[key].flatMap { i in
                counts.indices.contains(i) && counts[i] == maxCount ? i : nil
            } ?? counts.firstIndex(of: maxCount)!
            territory[winner] += 1
        }
        return (0..<7).map { ($0, population[$0], territory[$0]) }
    }
}

enum BioGridEngine {
    static let letters = ["L", "M", "X", "J", "V", "S", "D"]

    /// Ninguna de estas probabilidades es mortalidad natural: solo hay
    /// víctimas durante combates con al menos dos familias.
    enum Conflict: String, Equatable {
        case skirmish, births, reinforcement, invasion

        var risk: ClosedRange<Double> {
            switch self {
            case .skirmish:      return 0.0...0.02
            case .births:        return 0.02...0.06
            case .reinforcement: return 0.03...0.07
            case .invasion:      return 0.05...0.15
            }
        }
    }

    /// Los nacimientos pertenecen al DÍA ANTERIOR: provocan tensión
    /// en el combate de la medianoche siguiente. Las llegadas son nocturnas.
    static func conflictType(previousBirths: [Int64],
                             arrivals: [Int64],
                             defendingFamily: Int?) -> Conflict {
        let arrived = arrivals.enumerated().filter { $0.element > 0 }.map(\.offset)
        if !arrived.isEmpty {
            if let defendingFamily {
                if arrived.contains(where: { $0 != defendingFamily }) {
                    return .invasion
                }
            } else if arrived.count > 1 {
                return .invasion
            }
            return .reinforcement
        }
        if previousBirths.contains(where: { $0 > 0 }) { return .births }
        return .skirmish
    }

    /// Direcciones N, S, E, O (0,1,2,3) relativas a la casilla de origen.
    static func neighbor(_ cell: Cell, direction: Int) -> Cell {
        switch direction {
        case 0: return Cell(row:cell.row + 1,column:cell.column)
        case 1: return Cell(row:cell.row - 1,column:cell.column)
        case 2: return Cell(row:cell.row,column:cell.column + 1)
        default: return Cell(row:cell.row,column:cell.column - 1)
        }
    }

    /// Priorizamos casillas vacías o rivales. Si todas las vecinas ya
    /// son de la familia propia, solamente reforzamos la(s) menos
    /// poblada(s), si tienen menos individuos TOTALES que el origen.
    /// Todo se evalúa sobre la fotografía anterior a las emigraciones.
    static func migrationTargets(cell: Cell, family: Int,
                                 populations: [String:[Int64]],
                                 rulers: [String:Int]) -> [Int] {
        let sourceTotal = populations[cell.id]?.reduce(Int64(0),+) ?? 0
        var expand:[Int] = []
        var reinforce:[(direction:Int,population:Int64)] = []
        for direction in 0..<4 {
            let adjacent = neighbor(cell,direction:direction)
            let key = adjacent.id
            let inhabitants = populations[key] ?? Array(repeating:0,count:7)
            let total = inhabitants.reduce(Int64(0),+)
            let dominantNeighbor = dominant(inhabitants,prior:rulers[key])
            if dominantNeighbor != family {
                expand.append(direction)
            } else if total < sourceTotal {
                reinforce.append((direction,total))
            }
        }
        if !expand.isEmpty { return expand }
        guard let lowest = reinforce.map(\.population).min() else { return [] }
        return reinforce.filter { $0.population == lowest }.map(\.direction)
    }

    /// Defensa territorial antes de emigrar:
    /// - únicamente una familia líder sin empate;
    /// - mínimo de 10 bacterias para optar a emigrar;
    /// - la guarnición restante debe conservar AL MENOS EL DOBLE
    ///   que la segunda familia, o al menos 10 si no hay rivales.
    ///
    /// Esta capacidad es un límite DEFENSIVO: la emigración efectiva
    /// está limitada adicionalmente al 20 % de la familia y al sorteo
    /// estocástico. Se evalúa el cierre anterior al movimiento simultáneo.
    static func defensiveMigrationLimit(_ counts: [Int64]) -> (family: Int, maximum: Int64)? {
        guard let family = counts.indices.max(by: {
            counts[$0] < counts[$1]
        }) else { return nil }
        let leader = counts[family]
        guard leader >= 10 else { return nil }
        let second = counts.indices.filter { $0 != family }
            .map { counts[$0] }.max() ?? 0
        // Doble dominio seguro, sin overflow cuando hay grandes cifras.
        // Si la líder solo iguala el doble, no existe excedente emigrable.
        guard second <= Int64.max / 2 else { return nil }
        let garrison = max(Int64(10), second * 2)
        guard leader > garrison else { return nil }
        return (family: family, maximum: leader - garrison)
    }

    /// La migración real no puede superar el 20 % de la familia,
    /// incluso si una muestra binomial excepcional fuera mayor.
    static func migrationTwentyPercentCap(_ dominantPopulation: Int64) -> Int64 {
        max(0, dominantPopulation / 5)
    }

    /// Probabilidad individual (siempre inferior al 20 %) que mantiene
    /// el comportamiento de menor emigración en cuadrículas pequeñas.
    static func migrationProbability(totalPopulation: Int64) -> Double {
        let total = Double(totalPopulation)
        return 0.20 * total / (total + 130.0)
    }

    private static var madrid: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        cal.firstWeekday = 2
        return cal
    }

    static func fingerprint(_ input: [AssignedInterval]) -> String {
        var h: UInt64 = 14_695_981_039_346_656_037
        for item in input {
            for value in [UInt64(bitPattern: Int64(item.start.timeIntervalSince1970 * 1000)),
                          UInt64(bitPattern: Int64(item.end.timeIntervalSince1970 * 1000)),
                          UInt64(bitPattern: Int64(item.cell.row)),
                          UInt64(bitPattern: Int64(item.cell.column))] {
                h = (h ^ value) &* 1_099_511_628_211
            }
        }
        return String(h, radix: 16) + ":" + String(input.count)
    }

    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return Double((z ^ (z >> 31)) >> 11) / 9_007_199_254_740_992.0
        }
        mutating func binomial(_ n: Int64, _ p: Double) -> Int64 {
            guard n > 0 else { return 0 }
            let p = min(1, max(0, p))
            if n <= 256 {
                var hits: Int64 = 0
                for _ in 0..<Int(n) { if next() < p { hits += 1 } }
                return hits
            }
            let mean = Double(n) * p
            let stdev = sqrt(Double(n) * p * (1 - p))
            let normal = sqrt(-2 * log(max(next(), 0.00000001))) * cos(2 * .pi * next())
            return min(n, max(0, Int64((mean + normal * stdev).rounded())))
        }
    }

    private static func seed(_ date: Date, cell: String, salt: UInt64) -> UInt64 {
        var hash = UInt64(bitPattern: Int64(date.timeIntervalSince1970)) ^ salt
        for byte in cell.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash
    }

    // Completa 300 segundos acumulados por cuadrícula. El día se decide en el
    // instante de completar el bloque; los restos sobreviven entre visitas.
    static func simulate(_ intervals: [AssignedInterval], now: Date = .now,
                         timezone: TimeZone = .current) -> BioGridSnapshot {
        let calendar = madrid
        let today = calendar.startOfDay(for: now)
        let canonical = TimeAttribution.canonical(intervals).sorted { $0.start < $1.start }
        var events: [Date: [String: [Int64]]] = [:]
        var remainder: [String: Double] = [:]
        var lastIntervalEnds: [String: Date] = [:]
        var first: Date?
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timezone

        for interval in canonical {
            var cursor = interval.start
            let end = min(interval.end, now)
            guard end > cursor else { continue }
            let key = interval.cell.id
            if end > (lastIntervalEnds[key] ?? .distantPast) {
                lastIntervalEnds[key] = end
            }
            var rest = remainder[key, default: 0]
            while cursor < end {
                let needed = max(0.000001, 300 - rest)
                let step = min(needed, end.timeIntervalSince(cursor))
                cursor = cursor.addingTimeInterval(step)
                rest += step
                if rest >= 299.999999 {
                    rest = 0
                    let day = calendar.startOfDay(for: cursor)
                    let weekday = local.component(.weekday, from: cursor)
                    let family = (weekday + 5) % 7 // domingo=1 -> D=6; lunes=2 -> L=0
                    if events[day] == nil { events[day] = [:] }
                    if events[day]![key] == nil { events[day]![key] = Array(repeating: 0, count: 7) }
                    events[day]![key]![family] += 1
                    if first == nil || day < first! { first = day }
                }
            }
            remainder[key] = rest
        }
        guard let start = first else { return BioGridSnapshot(sourceFingerprint: fingerprint(intervals)) }
        var living: [String: [Int64]] = [:]
        var previousDominant: [String: Int] = [:]
        var visited: Set<String> = []
        var daily: [BioGridDay] = []
        var historical: [BioGridHistoryPoint] = []
        var cellHistory: [String: [BioGridCellPoint]] = [:]
        var lastCellPopulations: [String: [Int64]] = [:]
        var territoryEvents: [BioGridTerritoryEvent] = []
        var cellDays: [String: [BioGridCellDay]] = [:]
        var day = start
        var firstDay = true

        while day <= today {
            var report = BioGridDay(date: day)
            var ledger: [String: BioGridCellDay] = [:]

            // 00:00 MADRID: la noche anterior termina, migraciones simultáneas
            // (cada bacteria recorre como máximo UNA casilla) y después combate.
            // Para preservar las secuencias deterministas anteriores se emplea
            // la fecha del día que acaba de terminar como semilla de azar.
            if !firstDay {
                let priorDay = calendar.date(byAdding: .day, value: -1, to: day)!
                let old = living
                var next = old
                for key in old.keys.sorted() {
                    guard let counts = old[key], let cell = parseCell(key) else { continue }
                    // Solo la líder con dominio asegurado puede enviar
                    // bacterias. Las minorías permanecen defendiendo.
                    guard let permission = defensiveMigrationLimit(counts) else { continue }
                    let total = counts.reduce(0,+)
                    let probability = migrationProbability(totalPopulation:total)
                    var rng = Random(state: seed(priorDay, cell: key, salt: 0x47c23))
                    // Orden histórico de reparto: S, N, O, E.
                    // Las columnas se registran siempre N, S, E, O.
                    // Conservar el orden evita alterar la evolución ya conocida.
                    let neighbors = [
                        Cell(row:cell.row - 1,column:cell.column),
                        Cell(row:cell.row + 1,column:cell.column),
                        Cell(row:cell.row,column:cell.column - 1),
                        Cell(row:cell.row,column:cell.column + 1)
                    ]
                    let directions = [1,0,3,2]
                    let opposite = [1,0,3,2]
                    let family = permission.family
                    let validTargets = migrationTargets(cell:cell,family:family,
                        populations:old,rulers:previousDominant)
                    guard !validTargets.isEmpty else { continue }
                    let stochastic = rng.binomial(counts[family], probability)
                    let moved = min(stochastic, permission.maximum,
                                    migrationTwentyPercentCap(counts[family]))
                    if moved > 0 {
                        next[key]![family] -= moved
                        report.migrated[family] += moved
                        var remaining = moved
                        var from = ledger[key] ?? BioGridCellDay(date:day)
                        // Conservamos el orden determinista de vecinos S,N,O,E.
                        let selected = (0..<4).filter {
                            validTargets.contains(directions[$0])
                        }
                        for (index,direction) in selected.enumerated() {
                            let count = index == selected.count - 1 ? remaining :
                                rng.binomial(remaining,
                                    1.0 / Double(selected.count - index))
                            remaining -= count
                            if count == 0 { continue }
                            from.departures[family][directions[direction]] += count
                            let target = neighbors[direction].id
                            if next[target] == nil {
                                next[target] = Array(repeating:0,count:7)
                            }
                            next[target]![family] += count
                            var to = ledger[target] ?? BioGridCellDay(date:day)
                            to.arrivals[family][opposite[directions[direction]]] += count
                            ledger[target] = to
                        }
                        ledger[key] = from
                    }
                }

                for key in next.keys.sorted() {
                    guard var counts = next[key] else { continue }
                    let prior = previousDominant[key] ?? dominant(old[key] ?? [], prior:nil)
                    var ruler = dominant(counts,prior:prior)
                    if (old[key]?.reduce(0,+) ?? 0) == 0, let ruler {
                        let oldSite = visited.contains(key)
                        if !oldSite { report.newCells[ruler] += 1 }
                        territoryEvents.append(BioGridTerritoryEvent(
                            date:day,cellKey:key,family:ruler,previousFamily:nil,
                            kind:oldSite ? .recolonization : .first))
                        visited.insert(key)
                    }

                    let active = counts.indices.filter { counts[$0] > 0 }
                    if active.count > 1, let strongest = ruler {
                        var record = ledger[key] ?? BioGridCellDay(date:day)
                        let incoming:[Int64] = (0..<7).map { record.arrived($0) }
                        let priorBirths = events[priorDay]?[key] ??
                            Array(repeating:0,count:7)
                        let conflict = conflictType(previousBirths:priorBirths,
                            arrivals:incoming,defendingFamily:prior)
                        var rng = Random(state:seed(priorDay,cell:key,salt:0xba761))
                        var fighters = counts

                        if conflict == .skirmish {
                            // Rencillas de pequeños grupos, elegidos al azar.
                            // 5-10 % de cada familia; a menudo nadie muere.
                            let share = 0.05 + 0.05 * rng.next()
                            for family in active {
                                fighters[family] = rng.binomial(counts[family],share)
                            }
                        }
                        let enemy = active.filter { $0 != strongest }
                            .reduce(Int64(0)) { $0 + fighters[$1] }
                        // La dominante no moviliza más de 2 por cada enemigo.
                        fighters[strongest] = min(fighters[strongest],enemy * 2)
                        let participants = fighters.reduce(Int64(0),+)
                        if participants > 0 {
                            let lower = conflict.risk.lowerBound
                            let upper = conflict.risk.upperBound
                            let intensity = lower + (upper - lower) * rng.next()
                            var proposed = [Int64](repeating:0,count:7)
                            for family in active {
                                let share = Double(fighters[family]) / Double(participants)
                                let risk = min(upper,max(0,
                                    intensity * (1.0 + 0.30 * (1.0 - 2.0 * share))))
                                proposed[family] = rng.binomial(fighters[family],risk)
                            }
                            // Límite TOTAL de bajas: 2 % en rencillas y
                            // 6/7/15 % en conflictos con novedades.
                            let capacity = Int64(
                                (Double(participants) * upper).rounded(.down))
                            var actual = proposed
                            let proposedTotal = proposed.reduce(Int64(0),+)
                            if proposedTotal > capacity {
                                // Reducción proporcional para no perjudicar
                                // a las primeras letras L/M/X al aplicar techo.
                                let ratio = Double(capacity) / Double(proposedTotal)
                                var granted:Int64 = 0
                                for family in active {
                                    actual[family] = Int64((Double(proposed[family]) *
                                        ratio).rounded(.down))
                                    granted += actual[family]
                                }
                                let priorities = active.sorted { a,b in
                                    let fractionA = Double(proposed[a])*ratio -
                                        Double(actual[a])
                                    let fractionB = Double(proposed[b])*ratio -
                                        Double(actual[b])
                                    return fractionA == fractionB ? a < b :
                                        fractionA > fractionB
                                }
                                for family in priorities where granted < capacity {
                                    guard actual[family] < proposed[family] else { continue }
                                    actual[family] += 1
                                    granted += 1
                                }
                            }
                            for family in active {
                                counts[family] -= actual[family]
                                report.deaths[family] += actual[family]
                                record.deaths[family] += actual[family]
                            }
                        }
                        ledger[key] = record
                        ruler = dominant(counts,prior:prior)
                    }
                    if let before = prior, let after = ruler, before != after {
                        report.conquests[after] += 1
                        territoryEvents.append(BioGridTerritoryEvent(
                            date:day,cellKey:key,family:after,
                            previousFamily:before,kind:.conquest))
                    }
                    if counts.reduce(0,+) == 0 {
                        next.removeValue(forKey:key)
                        previousDominant.removeValue(forKey:key)
                    } else {
                        next[key] = counts
                        if let ruler { previousDominant[key] = ruler }
                    }
                }
                living = next
            }
            firstDay = false

            // NACIMIENTOS del día (sin migración ni combate hasta la próxima
            // medianoche). Los minutos restantes sobreviven entre días.
            for key in (events[day] ?? [:]).keys.sorted() {
                guard let incoming = events[day]?[key] else { continue }
                var counts = living[key] ?? Array(repeating:0,count:7)
                let wasEmpty = counts.reduce(0,+) == 0
                for family in 0..<7 {
                    counts[family] += incoming[family]
                    report.births[family] += incoming[family]
                }
                var record = ledger[key] ?? BioGridCellDay(date:day)
                for family in 0..<7 { record.births[family] += incoming[family] }
                ledger[key] = record
                if wasEmpty, let family = incoming.firstIndex(where: { $0 > 0 }) {
                    let oldSite = visited.contains(key)
                    if !oldSite { report.newCells[family] += 1 }
                    territoryEvents.append(BioGridTerritoryEvent(
                        date:day,cellKey:key,family:family,previousFamily:nil,
                        kind:oldSite ? .recolonization : .first))
                    visited.insert(key)
                }
                living[key] = counts
            }

            for key in ledger.keys.sorted() {
                guard let entry = ledger[key], entry.hasActivity else { continue }
                cellDays[key,default:[]].append(entry)
            }
            daily.append(report)
            var total = [Int64](repeating:0,count:7)
            var territories = [Int](repeating:0,count:7)
            for (key,counts) in living {
                guard counts.contains(where:{ $0 > 0 }) else { continue }
                for family in 0..<7 { total[family] += counts[family] }
                let ruler = dominant(counts,prior:previousDominant[key])!
                previousDominant[key] = ruler
                territories[ruler] += 1
                if lastCellPopulations[key] != counts {
                    cellHistory[key,default:[]].append(BioGridCellPoint(
                        date:day,counts:counts))
                }
            }
            for key in lastCellPopulations.keys where living[key] == nil {
                cellHistory[key,default:[]].append(BioGridCellPoint(
                    date:day,counts:Array(repeating:0,count:7)))
            }
            lastCellPopulations = living
            historical.append(BioGridHistoryPoint(
                date:day,population:total,territory:territories))
            guard let following = calendar.date(byAdding:.day,value:1,to:day),
                  following > day else { break }
            day = following
        }
        return BioGridSnapshot(populations: living,days:daily,latestProcessed:today,
            sourceFingerprint:fingerprint(intervals),
            todayBirths:events[today] ?? [:],remainingSeconds:remainder,
            lastIntervalEnds:lastIntervalEnds,
            historical:historical,cellHistory:cellHistory,cellDays:cellDays,
            territoryEvents:territoryEvents,rulers:previousDominant)
    }

    private static func dominant(_ counts: [Int64], prior: Int?) -> Int? {
        guard let maxValue = counts.max(), maxValue > 0 else { return nil }
        if let prior, prior < counts.count, counts[prior] == maxValue { return prior }
        return counts.firstIndex(of: maxValue)
    }
    private static func parseCell(_ key: String) -> Cell? {
        let p = key.split(separator: ":")
        guard p.count == 2, let r = Int(p[0]), let c = Int(p[1]) else { return nil }
        return Cell(row: r, column: c)
    }
}
