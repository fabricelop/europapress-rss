import Foundation

/// Solo representación: nunca modifica las muestras ni los contadores.
enum GPSRouteSegments {
    static func split(_ fixes: [GPSHistoryFix]) -> [[GPSHistoryFix]] {
        GPSHistoryGrouping.chunks(fixes).filter { $0.count >= 2 }
    }
}

/// En los huecos de GPS la ubicación es desconocida: no mantener
/// falsamente un punto quieto ni inventar continuidad visual.
enum GPSPlaybackPosition {
    case observed(latitude: Double, longitude: Double)
    case interpolated(latitude: Double, longitude: Double)
    case unavailable

    var coordinates: (latitude: Double, longitude: Double)? {
        switch self {
        case let .observed(latitude, longitude), let .interpolated(latitude, longitude):
            return (latitude, longitude)
        case .unavailable: return nil
        }
    }

    static func at(_ date: Date, in fixes: [GPSHistoryFix]) -> GPSPlaybackPosition {
        guard let first = fixes.first, let last = fixes.last,
              date >= first.date, date <= last.date else { return .unavailable }
        for index in fixes.indices {
            let b = fixes[index]
            if date == b.date {
                return .observed(latitude: b.latitude, longitude: b.longitude)
            }
            if date < b.date {
                guard index > 0 else { return .unavailable }
                let a = fixes[index - 1]
                guard GPSHistoryGrouping.connected(a, b),
                      PlaybackGapPolicy.canInterpolate(seconds: b.date.timeIntervalSince(a.date)) else {
                    return .unavailable
                }
                let f = date.timeIntervalSince(a.date) / b.date.timeIntervalSince(a.date)
                return .interpolated(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                     longitude: a.longitude + (b.longitude - a.longitude) * f)
            }
        }
        return .unavailable
    }
}
