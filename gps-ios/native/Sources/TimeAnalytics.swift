import Foundation

enum TimePeriod: String, CaseIterable, Identifiable {
    case all, today, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Todo"
        case .today: return "Hoy"
        case .week: return "7 días"
        case .month: return "Mes"
        case .year: return "Año"
        }
    }
}

/// Solo consulta los intervalos originales. Nunca modifica tiempos registrados.
enum TimeAnalytics {
    static func window(for period: TimePeriod, now: Date, calendar: Calendar = .current) -> DateInterval? {
        switch period {
        case .all: return nil
        case .today: return DateInterval(start: calendar.startOfDay(for: now), end: now)
        case .week: return DateInterval(start: calendar.date(byAdding: .day, value: -7, to: now) ?? now, end: now)
        case .month: return DateInterval(start: calendar.dateInterval(of: .month, for: now)?.start ?? now, end: now)
        case .year: return DateInterval(start: calendar.dateInterval(of: .year, for: now)?.start ?? now, end: now)
        }
    }
    static func totals(_ intervals: [AssignedInterval], from: Date, to: Date) -> [String: TimeInterval] {
        guard from < to else { return [:] }
        var values: [String: TimeInterval] = [:]
        for segment in TimeAttribution.canonical(intervals) {
            let begin = max(from, segment.start), end = min(to, segment.end)
            guard begin < end else { continue }
            values[segment.cell.id, default: 0] += end.timeIntervalSince(begin)
        }
        return values
    }
    static func sum(_ values: [String: TimeInterval]) -> TimeInterval { values.values.reduce(0,+) }
    static func cell(_ id: String) -> Cell? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let row = Int(parts[0]), let col = Int(parts[1]) else { return nil }
        return Cell(row:row, column:col)
    }
}
