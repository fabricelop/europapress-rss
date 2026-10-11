import Foundation

/// Únicamente un resumen local para WidgetKit; las muestras GPS y la base
/// SQLite permanecen exclusivamente dentro del contenedor de la aplicación.
struct TimeWidgetSnapshot: Codable, Equatable {
    let recordedAt: Date
    let totalAssignedSeconds: TimeInterval
    let currentCellSeconds: TimeInterval
    let currentStaySeconds: TimeInterval?
    let currentCellName: String?
    let lastLocationAt: Date?
    let trackingEnabled: Bool
    let hasFix: Bool

    static func empty(at date: Date = Date()) -> TimeWidgetSnapshot {
        TimeWidgetSnapshot(recordedAt: date, totalAssignedSeconds: 0,
                           currentCellSeconds: 0, currentStaySeconds: nil,
                           currentCellName: nil, lastLocationAt: nil,
                           trackingEnabled: false, hasFix: false)
    }

    func locationIsRecent(at date: Date) -> Bool {
        guard hasFix, let lastLocationAt else { return false }
        let elapsed = date.timeIntervalSince(lastLocationAt)
        return elapsed >= -5 && elapsed <= 180
    }
}

enum TimeWidgetDuration {
    /// No muestra prefijos con cero ni asume valores en tiempo real.
    static func readable(_ seconds: TimeInterval) -> String {
        var remaining = Int(max(0, seconds).rounded(.down))
        let months = remaining / 2_592_000; remaining %= 2_592_000
        let days = remaining / 86_400; remaining %= 86_400
        let hours = remaining / 3_600; remaining %= 3_600
        let minutes = remaining / 60; remaining %= 60
        var parts: [String] = []
        if months > 0 { parts.append("\(months) \(months == 1 ? "mes" : "meses")") }
        if days > 0 { parts.append("\(days) d") }
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if remaining > 0 || parts.isEmpty { parts.append("\(remaining) s") }
        return parts.joined(separator: " ")
    }

    static func compact(_ seconds: TimeInterval) -> String {
        var remaining = Int(max(0, seconds).rounded(.down))
        let months = remaining / 2_592_000; remaining %= 2_592_000
        let days = remaining / 86_400; remaining %= 86_400
        let hours = remaining / 3_600; remaining %= 3_600
        let minutes = remaining / 60; remaining %= 60
        let pieces = [
            months > 0 ? "\(months)mes" : "",
            days > 0 ? "\(days)d" : "",
            hours > 0 ? "\(hours)h" : "",
            minutes > 0 ? "\(minutes)m" : "",
            remaining > 0 ? "\(remaining)s" : ""
        ].filter { !$0.isEmpty }
        return pieces.isEmpty ? "0s" : pieces.prefix(2).joined(separator: " ")
    }
}

/// El grupo debe estar autorizado por iOS para AMBOS targets, app y widget.
/// Con firma gratuita Sideloadly puede no existir esta autorización.
enum TimeWidgetStorage {
    static let groupID = "group.es.mimapadeltiempo.widgets"
    static let key = "time_widget_snapshot_v1"

    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }

    @discardableResult
    static func save(_ snapshot: TimeWidgetSnapshot) -> Bool {
        guard isAvailable,
              let defaults = UserDefaults(suiteName: groupID),
              let bytes = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(bytes, forKey: key)
        return true
    }

    static func read() -> TimeWidgetSnapshot? {
        guard isAvailable,
              let bytes = UserDefaults(suiteName: groupID)?.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(TimeWidgetSnapshot.self, from: bytes)
    }
}
