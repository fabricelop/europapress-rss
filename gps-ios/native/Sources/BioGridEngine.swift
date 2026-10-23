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
    var historical: [BioGridHistoryPoint] = []
    var cellHistory: [String: [BioGridCellPoint]] = [:]
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
        var first: Date?
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timezone

        for interval in canonical {
            var cursor = interval.start
            let end = min(interval.end, now)
            guard end > cursor else { continue }
            let key = interval.cell.id
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
        var day = start
        while day <= today {
            var report = BioGridDay(date: day)
            let births = events[day] ?? [:]
            for key in births.keys.sorted() {
                let incoming = births[key]!
                var counts = living[key] ?? Array(repeating: 0, count: 7)
                for i in 0..<7 { counts[i] += incoming[i]; report.births[i] += incoming[i] }
                if (living[key]?.reduce(0,+) ?? 0) == 0,
                   let family = incoming.firstIndex(where: { $0 > 0 }) {
                    let oldSite = visited.contains(key)
                    if !oldSite { report.newCells[family] += 1 }
                    territoryEvents.append(BioGridTerritoryEvent(date:day,
                        cellKey:key,family:family,previousFamily:nil,
                        kind:oldSite ? .recolonization : .first))
                    visited.insert(key)
                }
                living[key] = counts
            }
            if day < today {
                // Emigración simultánea: los recién llegados no vuelven a migrar hoy.
                let old = living
                var new = old
                for key in old.keys.sorted() {
                    guard let counts = old[key], let cell = parseCell(key) else { continue }
                    let total = counts.reduce(0, +)
                    let probability = 0.30 * Double(total) / (Double(total) + 130)
                    var rng = Random(state: seed(day, cell: key, salt: 0x47c23))
                    for f in 0..<7 {
                        let moved = rng.binomial(counts[f], probability)
                        guard moved > 0 else { continue }
                        new[key]![f] -= moved
                        report.migrated[f] += moved
                        let neighbors = [Cell(row: cell.row - 1, column: cell.column),
                                         Cell(row: cell.row + 1, column: cell.column),
                                         Cell(row: cell.row, column: cell.column - 1),
                                         Cell(row: cell.row, column: cell.column + 1)]
                        var pending = moved
                        for i in 0..<4 {
                            let portion = i == 3 ? pending : rng.binomial(pending, 1.0 / Double(4 - i))
                            pending -= portion
                            if portion == 0 { continue }
                            let target = neighbors[i].id
                            if new[target] == nil { new[target] = Array(repeating: 0, count: 7) }
                            new[target]![f] += portion
                        }
                    }
                }
                // Familias nuevas, conquistas y batallas generales por cuadrícula.
                for key in new.keys.sorted() {
                    guard var counts = new[key] else { continue }
                    let prior = previousDominant[key] ?? dominant(old[key] ?? [], prior: nil)
                    var ruler = dominant(counts, prior: prior)
                    if (old[key]?.reduce(0,+) ?? 0) == 0, let ruler {
                        let oldSite = visited.contains(key)
                        if !oldSite { report.newCells[ruler] += 1 }
                        territoryEvents.append(BioGridTerritoryEvent(date:day,
                            cellKey:key,family:ruler,previousFamily:nil,
                            kind:oldSite ? .recolonization : .first))
                        visited.insert(key)
                    }
                    let active = counts.indices.filter { counts[$0] > 0 }
                    if active.count > 1, let strongest = ruler {
                        let enemy = active.filter { $0 != strongest }.reduce(Int64(0)) { $0 + counts[$1] }
                        var fighters = counts
                        fighters[strongest] = min(counts[strongest], enemy * 2)
                        let participants = fighters.reduce(Int64(0), +)
                        var rng = Random(state: seed(day, cell: key, salt: 0xba761))
                        let intensity = 0.05 + 0.10 * rng.next()
                        for f in active {
                            let share = Double(fighters[f]) / Double(max(1, participants))
                            let risk = intensity * (1.0 + 0.30 * (1.0 - 2.0 * share))
                            let dead = rng.binomial(fighters[f], risk)
                            counts[f] -= dead
                            report.deaths[f] += dead
                        }
                        ruler = dominant(counts, prior: prior)
                    }
                    if let before = prior, let after = ruler, before != after {
                        report.conquests[after] += 1
                        territoryEvents.append(BioGridTerritoryEvent(date:day,
                            cellKey:key,family:after,previousFamily:before,kind:.conquest))
                    }
                    if counts.reduce(0, +) == 0 { new.removeValue(forKey: key); previousDominant.removeValue(forKey: key) }
                    else { new[key] = counts; if let ruler { previousDominant[key] = ruler } }
                }
                living = new
            }
            daily.append(report)
            var total = [Int64](repeating:0,count:7)
            var territories = [Int](repeating:0,count:7)
            for (key, counts) in living {
                guard let maximum = counts.max(), maximum > 0 else { continue }
                for i in 0..<7 { total[i] += counts[i] }
                let ruler = dominant(counts, prior:previousDominant[key])!
                previousDominant[key] = ruler
                territories[ruler] += 1
                if lastCellPopulations[key] != counts {
                    cellHistory[key,default:[]].append(BioGridCellPoint(date:day,counts:counts))
                }
            }
            for key in lastCellPopulations.keys where living[key] == nil {
                cellHistory[key,default:[]].append(BioGridCellPoint(date:day,
                    counts:Array(repeating:0,count:7)))
            }
            lastCellPopulations = living
            historical.append(BioGridHistoryPoint(date:day,
                population:total,territory:territories))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return BioGridSnapshot(populations: living,days:daily,latestProcessed:today,
            sourceFingerprint:fingerprint(intervals),
            todayBirths:events[today] ?? [:],remainingSeconds:remainder,
            historical:historical,cellHistory:cellHistory,
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
