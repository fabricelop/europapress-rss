import Foundation

struct GPSHistoryEpisode: Identifiable {
    enum Kind: String { case journey = "Trayecto", stay = "Estancia" }
    let id: String
    let kind: Kind
    let points: [GPSHistoryFix]
    var start: Date { points.first!.date }
    var end: Date { points.last!.date }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum GPSHistoryGrouping {
    static let gapLimit: TimeInterval = 180
    static let stayThreshold: TimeInterval = 20 * 60
    static let stayRadius = 65.0

    static func distance(_ a: GPSHistoryFix, _ b: GPSHistoryFix) -> Double {
        let radians = Double.pi / 180
        let x = (b.latitude - a.latitude) * radians
        let y = (b.longitude - a.longitude) * radians
        let h = pow(sin(x / 2), 2) + cos(a.latitude * radians) *
            cos(b.latitude * radians) * pow(sin(y / 2), 2)
        return 12_742_000 * asin(min(1, sqrt(max(0, h))))
    }

    static func connected(_ a: GPSHistoryFix, _ b: GPSHistoryFix) -> Bool {
        let dt = b.date.timeIntervalSince(a.date)
        return dt > 0 && dt <= gapLimit &&
            distance(a, b) <= dt * 380 + 1000
    }

    static func chunks(_ input: [GPSHistoryFix]) -> [[GPSHistoryFix]] {
        let ordered = input.sorted { $0.date < $1.date }
        guard let first = ordered.first else { return [] }
        var result: [[GPSHistoryFix]] = []
        var active = [first]
        for point in ordered.dropFirst() {
            if let last = active.last, connected(last, point) {
                active.append(point)
            } else {
                result.append(active)
                active = [point]
            }
        }
        result.append(active)
        return result
    }
}
