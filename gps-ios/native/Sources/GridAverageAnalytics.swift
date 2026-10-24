import Foundation
import MapKit

/// Read-only statistics from the canonical, non-overlapping GPS history.
/// A visit ends only when the recorded cell changes, matching the existing
/// per-cell visit counter. Corrections and gaps do not create fake visits.
struct GridAverageStat: Identifiable {
    let cell: Cell
    let visits: Int
    let seconds: TimeInterval
    let squaredVisitSeconds: Double
    var id: String { cell.id }
    var average: TimeInterval { visits > 0 ? seconds / Double(visits) : 0 }

    /// Coefficient of variation of per-visit durations (population CV).
    /// A minimum of three actual visits prevents misleading certainty.
    var variation: Double? {
        guard visits >= 3, average > 0 else { return nil }
        let variance = max(0, squaredVisitSeconds / Double(visits) - average * average)
        return sqrt(variance) / average
    }
}

struct GridAverageSnapshot {
    let cells: [GridAverageStat]
    let globalAverage: TimeInterval
    let totalVisits: Int
    let totalSeconds: TimeInterval
    let byID: [String: GridAverageStat]

    init(cells: [GridAverageStat]) {
        let ordered = cells.sorted { $0.id < $1.id }
        self.cells = ordered
        byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        totalVisits = cells.reduce(0) { $0 + $1.visits }
        totalSeconds = cells.reduce(0) { $0 + $1.seconds }
        globalAverage = totalVisits > 0 ? totalSeconds / Double(totalVisits) : 0
    }

    var aboveAverage: Int { cells.filter { $0.average > globalAverage }.count }
    var belowAverage: Int { cells.filter { $0.average < globalAverage }.count }
    var stable: Int { cells.filter { ($0.variation ?? .infinity) <= 0.25 }.count }
    var variable: Int { cells.filter { ($0.variation ?? -1) >= 0.75 }.count }
    var evaluated: Int { cells.filter { $0.variation != nil }.count }
    var longestRepeatedAverage: TimeInterval {
        cells.filter { $0.visits >= 2 }.map(\.average).max() ?? 0
    }
    var greatestDifference: TimeInterval {
        cells.map { abs($0.average - globalAverage) }.max() ?? 0
    }

    /// Draw only cells in the visible viewport, bounded for MapKit performance.
    /// Each grid cell remains independent regardless of map zoom.
    func visible(near region: MKCoordinateRegion?, limit: Int = 1600) -> [GridAverageStat] {
        guard limit > 0 else { return [] }
        guard let region else {
            return Array(cells.sorted {
                $0.visits == $1.visits ? $0.id < $1.id : $0.visits > $1.visits
            }.prefix(limit))
        }
        let latitude = region.center.latitude
        let longitude = region.center.longitude
        let halfLat = region.span.latitudeDelta * 0.72
        let halfLon = region.span.longitudeDelta * 0.72
        let candidates = cells.filter { stat in
            let center = Grid.center(stat.cell)
            let distance = abs(center.longitude - longitude)
            return abs(center.latitude - latitude) <= halfLat &&
                   min(distance, 360 - distance) <= halfLon
        }
        return Array(candidates.sorted {
            $0.visits == $1.visits ? $0.id < $1.id : $0.visits > $1.visits
        }.prefix(limit))
    }
}

private struct GridAverageAccumulator {
    var seconds: TimeInterval = 0
    var visits: Int = 0
    var sumOfVisitSquares: Double = 0
}

enum GridAverageEngine {
    static func calculate(_ raw: [AssignedInterval],
                          period: TimePeriod = .all,
                          now: Date = .now,
                          calendar: Calendar = .current) -> GridAverageSnapshot {
        let window = TimeAnalytics.window(for: period, now: now, calendar: calendar)
        var totals: [String: GridAverageAccumulator] = [:]
        var knownCells: [String: Cell] = [:]
        var activeID: String?
        var activeDuration: TimeInterval = 0

        func finishVisit() {
            guard let id = activeID, activeDuration > 0 else { return }
            var accumulator = totals[id] ?? GridAverageAccumulator()
            accumulator.visits += 1
            accumulator.seconds += activeDuration
            accumulator.sumOfVisitSquares += activeDuration * activeDuration
            totals[id] = accumulator
        }

        for interval in TimeAttribution.canonical(raw) where interval.end > interval.start {
            let id = interval.cell.id
            if id != activeID {
                finishVisit()
                activeID = id
                activeDuration = 0
            }
            let start = max(interval.start, window?.start ?? interval.start)
            let end = min(interval.end, window?.end ?? interval.end)
            guard end > start else { continue }
            knownCells[id] = interval.cell
            activeDuration += end.timeIntervalSince(start)
        }
        finishVisit()

        let values = totals.compactMap { id, item -> GridAverageStat? in
            guard item.visits > 0, let cell = knownCells[id] else { return nil }
            return GridAverageStat(cell: cell, visits: item.visits,
                                   seconds: item.seconds,
                                   squaredVisitSeconds: item.sumOfVisitSquares)
        }
        return GridAverageSnapshot(cells: values)
    }
}
