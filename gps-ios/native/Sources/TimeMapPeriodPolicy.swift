import Foundation

/// Interpretacion visual de los filtros de tiempo. Los registros GPS originales
/// nunca se recortan, se editan ni se persisten desde este calculo.
enum TimeMapPeriodPolicy {
    /// Una estancia puede comenzar antes de "Hoy", de "7 dias", etc.
    /// Mostrar solamente su interseccion con el periodo elegido.
    static func clippedStay(_ completeSeconds: TimeInterval,
                            period: TimePeriod,
                            now: Date = .now,
                            calendar: Calendar = .current) -> TimeInterval {
        guard completeSeconds.isFinite, completeSeconds > 0 else { return 0 }
        guard let window = TimeAnalytics.window(for: period, now: now,
                                                calendar: calendar) else {
            return completeSeconds
        }
        return min(completeSeconds, max(0, now.timeIntervalSince(window.start)))
    }

    /// El dia en curso invalida siempre las cachés de Hoy/Mes/Ano.
    /// Los siete dias constituyen una ventana movil: refrescarla cada minuto.
    /// Este indice NO necesita recalcular las muestras GPS cada segundo.
    static func refreshBucket(for period: TimePeriod,
                              now: Date = .now,
                              calendar: Calendar = .current) -> Int64 {
        switch period {
        case .all:
            return 0
        case .week:
            return Int64(floor(now.timeIntervalSince1970 / 60))
        case .today, .month, .year:
            return Int64(calendar.startOfDay(for: now).timeIntervalSince1970.rounded())
        }
    }
}
