import Foundation
import CoreLocation

/// Un intervalo sin observaciones GPS no es automáticamente una estancia.
/// Solo se ofrece cuando hay anclajes GPS fiables, antes y después, en la
/// misma cuadrícula. La confirmación explícita del usuario es imprescindible.
struct TimeGPSGapCandidate:Identifiable,Equatable {
    let start:Date
    let end:Date
    let cell:Cell
    var id:String { "\(cell.id)-\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    var seconds:TimeInterval { end.timeIntervalSince(start) }
}

enum TimeGPSGapRecovery {
    static let minimumGap:TimeInterval=180
    static let maximumGap:TimeInterval=12*3600
    static let maximumAnchorAge:TimeInterval=180
    static let maximumAnchorAccuracy=45.0

    static func candidates(intervals:[AssignedInterval],fixes:[GPSPoint],
                           manualBreaks:[Date],events:[GPSPowerEvent],
                           cells:Set<String>)->[TimeGPSGapCandidate] {
        guard !cells.isEmpty else { return [] }
        let ordered=TimeAttribution.canonical(intervals)
        guard ordered.count>1 else { return [] }
        // Compresión del histórico: mantener ambas direcciones de búsqueda,
        // sin exigir puntos GPS dentro de un hueco.
        let anchors=fixes.filter {
            $0.accuracy>=0 && $0.accuracy<=maximumAnchorAccuracy
        }.sorted { $0.date<$1.date }
        var result:[TimeGPSGapCandidate]=[]
        for i in 1..<ordered.count {
            let before=ordered[i-1],after=ordered[i]
            let gap=after.start.timeIntervalSince(before.end)
            guard gap>=minimumGap && gap<=maximumGap,
                  before.cell==after.cell,cells.contains(before.cell.id),
                  !manualBreaks.contains(where:{$0>=before.end && $0<=after.start}),
                  !events.contains(where:{
                      $0.date>=before.end && $0.date<=after.start &&
                      ($0.cause.contains("Seguimiento detenido") ||
                       $0.cause.contains("Pausa voluntaria"))
                  }) else { continue }
            guard let first=anchors.last(where:{
                $0.date<=before.end &&
                before.end.timeIntervalSince($0.date)<=maximumAnchorAge &&
                $0.cell==before.cell
            }), let last=anchors.first(where:{
                $0.date>=after.start &&
                $0.date.timeIntervalSince(after.start)<=maximumAnchorAge &&
                $0.cell==after.cell
            }) else { continue }
            let distance=CLLocation(latitude:first.latitude,longitude:first.longitude)
                .distance(from:CLLocation(latitude:last.latitude,longitude:last.longitude))
            guard distance<=max(25,(first.accuracy+last.accuracy)*1.1) else { continue }
            // Una posición fiable que señale otra casilla entre los dos anclajes
            // impide incluso ofrecer la recuperación.
            guard !anchors.contains(where:{
                $0.date>before.end && $0.date<after.start &&
                $0.cell != before.cell
            }) else { continue }
            result.append(TimeGPSGapCandidate(start:before.end,end:after.start,cell:before.cell))
        }
        return result
    }
}

/// Resultado real de la confirmación; la interfaz nunca debe asumir éxito
/// simplemente porque el usuario pulsó el botón de confirmación.
enum TimeGPSGapConfirmationOutcome:Equatable {
    case saved(TimeInterval)
    case noLongerAvailable
    case storageFailure(String)

    var isSuccess:Bool {
        if case .saved = self { return true }
        return false
    }
    var message:String {
        switch self {
        case .saved(let seconds):
            return "\(DurationFormat.full(seconds)) añadidos a la estancia como tiempo estimado (no GPS observado)."
        case .noLongerAvailable:
            return "El intervalo ha cambiado desde que abriste la confirmación. No se ha añadido ningún tiempo. Revisa de nuevo el hueco."
        case .storageFailure(let explanation):
            return "No se pudo guardar el tiempo recuperado: \(explanation)"
        }
    }
}
