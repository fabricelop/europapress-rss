import Foundation
import ActivityKit

/// Los cambios de estado se publican con moderación; el reloj del sistema
/// avanza por sí solo mediante Text(date, style: .timer).
@MainActor final class TimeLiveActivityPublisher {
    private var lastUpdated: Date = .distantPast
    private var lastName: String?
    private var lastResting: Bool?

    func refresh(from model: TimeModel, force: Bool = false, now: Date = .now) {
        let enabled = UserDefaults.standard.bool(forKey: "miMapaLiveActivity")
        let activities = Activity<TimeMapActivityAttributes>.activities
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !activities.isEmpty {
                Task {
                    for activity in activities { await activity.end(nil, dismissalPolicy:.immediate) }
                }
            }
            return
        }
        guard let cell = model.activeCell,
              let start = model.currentVisitStart ?? model.data.gpsRest?.startedAt,
              model.recording || model.isResting else {
            if !activities.isEmpty {
                Task {
                    for activity in activities { await activity.end(nil, dismissalPolicy:.immediate) }
                }
            }
            return
        }
        let name = model.label(for:cell)
        let rest = model.isResting
        let changed = lastName != name || lastResting != rest
        guard force || changed || now.timeIntervalSince(lastUpdated) >= 120 else { return }
        lastUpdated = now
        lastName = name
        lastResting = rest
        let state = TimeMapActivityAttributes.ContentState(
            cellName:name,stayStartedAt:start,resting:rest)
        let content = ActivityContent(state:state,staleDate:nil)
        Task {
            if let current = Activity<TimeMapActivityAttributes>.activities.first {
                await current.update(content)
            } else {
                do {
                    _ = try Activity<TimeMapActivityAttributes>.request(
                        attributes:TimeMapActivityAttributes(),
                        content:content,pushType:nil)
                } catch {
                    // El usuario verá el estado real en Ajustes; iOS y la firma
                    // pueden denegar Live Activities, nunca fingir éxito.
                }
            }
        }
    }
}
