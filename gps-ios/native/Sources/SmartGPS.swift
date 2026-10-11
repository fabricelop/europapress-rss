import Foundation
import CoreMotion
import CoreLocation

struct GPSPowerEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    let date: Date
    let mode: String
    let cause: String
}

enum GPSPowerMode: String {
    case precision = "Máxima precisión"
    case rest = "Reposo inteligente"
}

/// Política conservadora de continuidad: no se permite un reposo automático
/// que podría suspender la aplicación antes de que CoreMotion pueda despertarla.
/// La intención "Voy a moverme" es solo informativa y nunca altera el GPS.
struct SmartGPSDecision {
    private(set) var mode: GPSPowerMode = .precision
    private(set) var movingSoon = false
    private(set) var lastActivity: Date?

    mutating func anticipate() { movingSoon = true }
    mutating func cancelAnticipation() { movingSoon = false }

    mutating func observe(date: Date, speed: Double, metersSincePrevious: Double,
                          motionMoving: Bool?) {
        if motionMoving == true || speed >= 1.15 || metersSincePrevious >= 28 {
            lastActivity = date
            movingSoon = false
        }
        // Sin transición a .rest: la ausencia de nuevas posiciones no prueba
        // inmovilidad y ningún callback CoreMotion garantiza despertar iOS.
    }
    mutating func motionStarted(at date: Date) {
        lastActivity = date
        movingSoon = false
    }
}

/// Core Motion tiene notificaciones de actividad cuando el sistema las facilita.
/// No asegura despertarse instantáneamente tras un bloqueo prolongado.
final class MotionObserver {
    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()
    private(set) var available = CMMotionActivityManager.isActivityAvailable()
    private var handler: ((Bool?) -> Void)?

    func begin(_ callback: @escaping (Bool?) -> Void) {
        guard available else { callback(nil); return }
        handler = callback
        manager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let activity else { return }
            let moving = activity.walking || activity.running || activity.automotive || activity.cycling
            let stopped = activity.stationary
            self?.handler?(moving ? true : stopped ? false : nil)
        }
    }
    func end() {
        manager.stopActivityUpdates()
        handler = nil
    }
}
