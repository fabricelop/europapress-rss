import Foundation

enum GPSHealthAssessment:Equatable {
    case stopped,paused,waiting,recent,delayed(Int),stale(Int)
    static func evaluate(recording:Bool,resting:Bool,
                         lastFix:Date?,now:Date)->GPSHealthAssessment {
        if resting { return .paused }
        guard recording else { return .stopped }
        guard let lastFix else { return .waiting }
        let age=Int(max(0,now.timeIntervalSince(lastFix)))
        if age<=45 { return .recent }
        if age<=120 { return .delayed(age) }
        return .stale(age)
    }
    var needsAttention:Bool {
        switch self { case .delayed,.stale: return true; default: return false }
    }
    var symbol:String {
        switch self {
        case .stopped: return "pause.circle"
        case .paused: return "moon.zzz.fill"
        case .waiting: return "location.magnifyingglass"
        case .recent: return "checkmark.circle.fill"
        case .delayed: return "clock.badge.exclamationmark"
        case .stale: return "exclamationmark.triangle.fill"
        }
    }
    var message:String {
        switch self {
        case .stopped: return "Seguimiento detenido"
        case .paused: return "GPS en pausa voluntaria · tiempo asumido"
        case .waiting: return "Buscando posición GPS"
        case .recent: return "Seguimiento correcto · GPS reciente"
        case .delayed(let seconds): return "GPS retrasado · \(seconds) s"
        case .stale(let seconds): return "Sin GPS reciente · \(seconds / 60) min"
        }
    }
}
