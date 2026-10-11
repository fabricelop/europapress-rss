import Foundation

/// Suaviza únicamente la cifra mostrada. Nunca escribe segundos estimados
/// en SQLite ni sustituye los intervalos GPS confirmados.
enum LiveCounterProjection {
    /// `cacheEnd` es la última fecha incluida en la proyección normalizada
    /// que realmente respalda el contador mostrado, no necesariamente la
    /// última muestra que CoreLocation acaba de comunicar.
    static func provisionalSeconds(recording:Bool,
                                   currentLocationInTarget:Bool,
                                   lastFix:Date?,
                                   cacheEnd:Date?,
                                   currentVisitStart:Date?,
                                   periodStart:Date?,
                                   now:Date,
                                   maximumAge:TimeInterval = 120) -> TimeInterval {
        guard recording,currentLocationInTarget,
              let lastFix,lastFix <= now else { return 0 }
        let age=now.timeIntervalSince(lastFix)
        // Una muestra muy antigua deja el reloj provisional detenido;
        // el avance hasta ese límite se conserva para evitar un salto atrás.
        let allowedThrough=min(now,lastFix.addingTimeInterval(maximumAge))
        let anchor=max(cacheEnd ?? lastFix,
                       currentVisitStart ?? lastFix,
                       periodStart ?? .distantPast)
        guard allowedThrough>anchor else { return 0 }
        return allowedThrough.timeIntervalSince(anchor)
    }
}
