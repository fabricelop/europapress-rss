import Foundation
import WidgetKit

/// WidgetKit asigna límites a las recargas; no invocar por muestra/segundo.
@MainActor final class TimeWidgetPublisher {
    private var lastPublishedAt: Date = .distantPast
    private var lastCellID: String?
    private var lastTrackingEnabled: Bool?
    private(set) var lastPublishedSuccessfully = false

    func publish(from model: TimeModel, force: Bool = false, at now: Date = .now) {
        let cell = model.activeCell
        let changed = lastCellID != cell?.id || lastTrackingEnabled != model.recording
        guard force || changed || now.timeIntervalSince(lastPublishedAt) >= 300 else { return }

        let lastLocationAt = model.lastGPSFix
        let recent = lastLocationAt.map {
            let elapsed = now.timeIntervalSince($0)
            return elapsed >= -5 && elapsed <= 180
        } ?? false
        let stay: TimeInterval?
        if recent, model.recording, let lastLocationAt,
           let start = model.currentVisitStart, lastLocationAt >= start {
            stay = lastLocationAt.timeIntervalSince(start)
        } else { stay = nil }
        let snapshot = TimeWidgetSnapshot(
            recordedAt: now,
            totalAssignedSeconds: model.totalSeconds,
            currentCellSeconds: cell.map { model.data.totals[$0.id] ?? 0 } ?? 0,
            currentStaySeconds: stay,
            currentCellName: cell.map { model.label(for: $0) },
            lastLocationAt: lastLocationAt,
            trackingEnabled: model.recording,
            hasFix: recent
        )
        lastPublishedSuccessfully = TimeWidgetStorage.save(snapshot)
        guard lastPublishedSuccessfully else { return }
        lastPublishedAt = now
        lastCellID = cell?.id
        lastTrackingEnabled = model.recording
        WidgetCenter.shared.reloadTimelines(ofKind: "MiMapaTiempoWidget")
    }
}
