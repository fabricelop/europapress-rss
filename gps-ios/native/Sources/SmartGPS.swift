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

/// Decisión de modo separada del GPS real, comprobable con datos ficticios.
struct SmartGPSDecision {
    private(set) var mode: GPSPowerMode = .precision
    private(set) var movingSoon = false
    private(set) var restSince: Date?
    private(set) var lastActivity: Date?
    static let quietThreshold: TimeInterval = 10 * 60

    mutating func anticipate() {
        movingSoon = true
        mode = .precision
        restSince = nil
    }
    mutating func cancelAnticipation() {
        movingSoon = false
        mode = .precision
        restSince = nil // Auto: una parada nueva debe ser confirmada, no presupuesta.
    }
    mutating func observe(date: Date, speed: Double, metersSincePrevious: Double,
                          motionMoving: Bool?) {
        let moving = motionMoving == true || speed >= 1.15 || metersSincePrevious >= 28
        if moving {
            restSince = nil
            lastActivity = date
            mode = .precision
            return
        }
        // Core Motion explícitamente inmóvil o GPS sin desplazamiento relevante.
        if restSince == nil { restSince = date }
        if let restSince, date.timeIntervalSince(restSince) >= Self.quietThreshold {
            movingSoon = false
            mode = .rest
        }
    }
    mutating func motionStarted(at date: Date) {
        lastActivity = date
        restSince = nil
        mode = .precision
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
