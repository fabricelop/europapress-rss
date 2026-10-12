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
