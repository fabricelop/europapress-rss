import Foundation
import ActivityKit

/// Se comparten únicamente resúmenes con la extensión. Nunca coordenadas ni SQLite.
/// Los totales son confirmados, no incluyen segundos interpolados sin un nuevo GPS.
struct TimeMapActivityAttributes:ActivityAttributes {
    struct ContentState:Codable,Hashable {
        var cellName:String
        var cellNumber:String
        var zoneName:String?
        var confirmedCellSeconds:TimeInterval
        var confirmedZoneSeconds:TimeInterval?
        var stayStartedAt:Date
        var timerValidUntil:Date
        var lastGPSAt:Date?
        var resting:Bool
        // 9 niveles relativos, índice 4 es la casilla central.
        var nearbyIntensity:[Int]
        // Porcentaje de presencia CONFIRMADA en cada hora (0...100).
        var lastSixHours:[Int]
        var chartIsZone:Bool
    }
    var title="Mi Mapa Prueba"
}

/// Una nueva visita a la misma zona exige un cronómetro nuevo.
/// Además del lugar comparamos la casilla física y la hora real de comienzo.
struct TimeActivityFingerprint:Equatable {
    let cellID:String
    let visibleName:String
    let startedAt:Date
    let resting:Bool
}

enum TimeLiveDuration {
    static func compact(_ seconds:TimeInterval)->String {
        let safe=Int(max(0,seconds).rounded(.down))
        if safe>=86400 { return "\(safe/86400)d \((safe%86400)/3600)h" }
        if safe>=3600 { return "\(safe/3600)h \((safe%3600)/60)m" }
        if safe>=60 { return "\(safe/60)m \(safe%60)s" }
        return "\(safe)s"
    }
}
