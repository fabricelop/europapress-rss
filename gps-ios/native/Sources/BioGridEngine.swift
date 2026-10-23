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

    /// Defensa territorial antes de emigrar:
    /// - únicamente una familia líder sin empate;
    /// - mínimo de 10 bacterias para optar a emigrar;
    /// - la guarnición restante debe conservar una ventaja del 30 %
    ///   frente a la segunda familia, o al menos 10 si no hay rivales.
    ///
    /// La capacidad es un techo, no una emigración obligatoria: después
    /// se aplica la misma probabilidad estocástica que en BIOGRID 1.0.48.
    /// Se calcula sobre el estado del cierre anterior al movimiento simultáneo.
    static func defensiveMigrationLimit(_ counts: [Int64]) -> (family: Int, maximum: Int64)? {
        guard let family = counts.indices.max(by: {
            counts[$0] < counts[$1]
        }) else { return nil }
        let leader = counts[family]
        guard leader >= 10 else { return nil }
        let second = counts.indices.filter { $0 != family }
            .map { counts[$0] }.max() ?? 0
        guard leader > second else { return nil }

        // ceil(second * 0.30), usando aritmética entera para evitar
        // errores de redondeo en los límites exactos del 30 %.
        let reserveAgainstRival = second + (second * 3 + 9) / 10
        let garrison = max(Int64(10), reserveAgainstRival)
        guard leader > garrison else { return nil }
        return (family: family, maximum: leader - garrison)
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
                    let probability = 0.30 * Double(total) / (Double(total) + 130)
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
                    let stochastic = rng.binomial(counts[family], probability)
                    let moved = min(stochastic, permission.maximum)
                    if moved > 0 {
                        next[key]![family] -= moved
                        report.migrated[family] += moved
                        var remaining = moved
                        var from = ledger[key] ?? BioGridCellDay(date:day)
                        for direction in 0..<4 {
                            let count = direction == 3 ? remaining :
                                rng.binomial(remaining,1.0 / Double(4 - direction))
                            remaining -= count
                            if count == 0 { continue }
                            from.departures[family][directions[direction]] += count
                            let target = neighbors[direction].id
                            if next[target] == nil {
                                next[target] = Array(repeating: 0, count: 7)
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
                        let enemy = active.filter { $0 != strongest }
                            .reduce(Int64(0)) { $0 + counts[$1] }
                        var fighters = counts
                        fighters[strongest] = min(counts[strongest], enemy * 2)
                        let participants = fighters.reduce(Int64(0),+)
                        var rng = Random(state:seed(priorDay,cell:key,salt:0xba761))
                        let intensity = 0.05 + 0.10 * rng.next()
                        var record = ledger[key] ?? BioGridCellDay(date:day)
                        for family in active {
                            let share = Double(fighters[family]) / Double(max(1,participants))
                            let risk = intensity * (1.0 + 0.30 * (1.0 - 2.0 * share))
                            let dead = rng.binomial(fighters[family],risk)
                            counts[family] -= dead
                            report.deaths[family] += dead
                            record.deaths[family] += dead
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
