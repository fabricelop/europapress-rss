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
        // Modo contextual y datos de un recorrido confirmado por muestras GPS.
        var moving:Bool
        var recentDistanceMeters:Int
        var crossedCells:Int
        var trailIndices:[Int]
        var headingDegrees:Double?
        // Esta visita a la zona, distinta del tiempo histórico total.
        var currentZoneStaySeconds:TimeInterval?
        // Minutos reales de cada ventana del gráfico (última a la derecha).
        var lastSixMinutes:[Int]
        // Hitos discretos; no se envían notificaciones adicionales.
        var milestone:String?
        // Separate identified establishment, not merely the zone's label.
        // Optional for backwards decoding of Live Activities from old builds.
        var siteName:String?
        var siteConfirmed:Bool?
        // L, M, X, J, V, S, D in fixed order. Derived from BIOGRID's
        // current-cell snapshot; no game simulation inside the extension.
        var bioGridCounts:[Int64]?
        var bioGridUpdatedAt:Date?
    }
    var title="Mi Mapa del Tiempo"
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


/// View text only: no location inference and no mutation. An assigned place
/// is the main title when available; otherwise keep the existing grid/zone
/// name. Identifiers and GPS recording are unchanged.
enum TimeLiveCompactPresentation {
    static func title(site:String?,fallback:String)->String {
        let clean=site?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? fallback : clean
    }
    static func isProposed(site:String?,confirmed:Bool?)->Bool {
        guard let site,!site.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        else { return false }
        return confirmed != true
    }
    static func families(_ counts:[Int64]?)->[Int64]? {
        guard let counts,counts.count == 7 else { return nil }
        return counts.map { max(0,$0) }
    }
}
