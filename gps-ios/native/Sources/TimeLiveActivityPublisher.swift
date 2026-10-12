import Foundation
import ActivityKit
import WidgetKit

/// Solicita y restaura la Live Activity sin App Group ni permisos de servidor.
/// iOS puede terminarla por su límite de duración; solo se recupera al abrir la app
/// o cuando el sistema realmente entrega una posición GPS.
@MainActor final class TimeLiveActivityPublisher {
    private var lastUpdated:Date = .distantPast
    private var lastFingerprint:TimeActivityFingerprint?
    private var updateTask:Task<Void,Never>?

    private func ongoingActivities()->[Activity<TimeMapActivityAttributes>] {
        Activity<TimeMapActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    func check(from model:TimeModel) {
        let enabled=ActivityAuthorizationInfo().areActivitiesEnabled
        let items=Activity<TimeMapActivityAttributes>.activities
        let states=items.map { "\($0.id.prefix(8)): \($0.activityState)" }.joined(separator:", ")
        model.liveActivityDiagnostic = "ActivityKit: \(enabled ? "autorizado" : "no permitido") · \(items.count) actividad(es)" +
            (states.isEmpty ? "" : " · "+states)
        let extensionURL=Bundle.main.builtInPlugInsURL?.appendingPathComponent("MiMapaWidgets.appex")
        let embedded=extensionURL.map { FileManager.default.fileExists(atPath:$0.path) } ?? false
        let extensionBundle=extensionURL.flatMap(Bundle.init(url:))
        let point=(extensionBundle?.infoDictionary?["NSExtension"] as? [String:Any])?["NSExtensionPointIdentifier"] as? String ?? "no consta"
        model.widgetDiagnostic=embedded ?
            "Extensión instalada · \(extensionBundle?.bundleIdentifier ?? "?") · \(point). App Group: \(TimeWidgetStorage.isAvailable ? "autorizado" : "no autorizado")." :
            "Extensión MiMapaWidgets.appex no incluida: revisar IPA y firma de Impactor."
        WidgetCenter.shared.getCurrentConfigurations { result in
            Task { @MainActor in
                switch result {
                case .success(let widgets):
                    model.widgetDiagnostic += " Widgets añadidos: \(widgets.count)."
                case .failure(let error):
                    model.widgetDiagnostic += " Error WidgetCenter: \(error.localizedDescription)"
                }
            }
        }
    }

    func restoreIfNeeded(from model:TimeModel) {
        guard UserDefaults.standard.bool(forKey:"miMapaLiveActivity") else { return }
        // Bypass del limitador si iOS ha terminado una actividad de 8 horas.
        if ongoingActivities().isEmpty {
            lastUpdated = .distantPast
            lastFingerprint=nil
            refresh(from:model,force:true)
        } else {
            refresh(from:model)
        }
    }

    /// Botón explícito: sustituye la actividad anterior y muestra una nueva.
    /// Si aún no hay GPS reciente, queda solicitada la reactivación en Ajustes
    /// y la primera muestra válida iniciará la actividad automáticamente.
    func reactivate(from model:TimeModel) {
        UserDefaults.standard.set(true,forKey:"miMapaLiveActivity")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            model.liveActivityDiagnostic="Actividades en directo desactivadas en Ajustes de iOS."
            return
        }
        updateTask?.cancel()
        updateTask=Task {
            for existing in Activity<TimeMapActivityAttributes>.activities {
                await existing.end(nil,dismissalPolicy:.immediate)
            }
            guard !Task.isCancelled else { return }
            lastFingerprint=nil
            lastUpdated = .distantPast
            refresh(from:model,force:true)
        }
    }

    func refresh(from model:TimeModel,force:Bool=false,now:Date = .now) {
        let enabled=UserDefaults.standard.bool(forKey:"miMapaLiveActivity")
        let permitted=ActivityAuthorizationInfo().areActivitiesEnabled
        guard enabled,permitted else {
            lastFingerprint=nil
            lastUpdated = .distantPast
            updateTask?.cancel()
            updateTask=Task {
                for activity in Activity<TimeMapActivityAttributes>.activities {
                    await activity.end(nil,dismissalPolicy:.immediate)
                }
            }
            return
        }
        guard let cell=model.activeCell,
              let start=model.currentVisitStart ?? model.data.gpsRest?.startedAt,
              model.recording || model.isResting else {
            model.liveActivityDiagnostic="En vivo preparado · esperando primera posición GPS."
            return
        }
        let resting=model.isResting
        // Nunca hacemos pasar la última posición histórica por una posición viva.
        let fix=resting ? nil : model.current?.date
        guard resting || fix != nil else {
            model.liveActivityDiagnostic="En vivo activado · esperando nueva posición GPS."
            return
        }
        let name=model.label(for:cell)
        let fingerprint=TimeActivityFingerprint(cellID:cell.id,
            visibleName:name,startedAt:start,resting:resting)
        let active=ongoingActivities()
        let changed=lastFingerprint != fingerprint
        guard force || changed || active.isEmpty ||
              now.timeIntervalSince(lastUpdated)>=45 else { return }

        let zone=model.primaryZone(for:cell)
        let confirmed=model.confirmedTotals(now:now)
        let zoneTotal:TimeInterval?=zone.map { zone in
            zone.cellIDs.reduce(0) { $0+(confirmed[$1] ?? 0) }
        }
        let end:Date
        if resting {
            // ActivityKit termina las actividades por duración. No se usa este
            // intervalo para asignar más tiempo al historial.
            end=max(start.addingTimeInterval(8*3600),now.addingTimeInterval(90))
        } else {
            end=max(start.addingTimeInterval(1),
                    (fix ?? now).addingTimeInterval(120))
        }
        let state=TimeMapActivityAttributes.ContentState(
            cellName:name,
            cellNumber:model.data.shortIDs[cell.id].map { "Cuadrícula \($0)" } ?? "Cuadrícula actual",
            zoneName:zone?.name,
            confirmedCellSeconds:confirmed[cell.id] ?? 0,
            confirmedZoneSeconds:zoneTotal,
            stayStartedAt:start,
            timerValidUntil:end,
            lastGPSAt:fix,
            resting:resting)
        let content=ActivityContent(
            state:state,
            staleDate:resting ? nil : fix?.addingTimeInterval(90),
            relevanceScore:60)
        lastUpdated=now
        lastFingerprint=fingerprint
        updateTask?.cancel()
        updateTask=Task {
            if let item=ongoingActivities().first {
                await item.update(content)
                guard !Task.isCancelled else { return }
                model.liveActivityDiagnostic="En vivo actualizado · \(item.id.prefix(12)) · \(item.activityState)"
            } else {
                do {
                    let item=try Activity<TimeMapActivityAttributes>.request(
                        attributes:TimeMapActivityAttributes(),
                        content:content,pushType:nil)
                    guard !Task.isCancelled else { return }
                    model.liveActivityDiagnostic="En vivo iniciado · \(item.id.prefix(12)) · \(item.activityState)"
                } catch {
                    guard !Task.isCancelled else { return }
                    lastUpdated = .distantPast
                    lastFingerprint=nil
                    model.liveActivityDiagnostic="No se pudo crear En vivo: \(String(reflecting:error))"
                }
            }
        }
    }
}
