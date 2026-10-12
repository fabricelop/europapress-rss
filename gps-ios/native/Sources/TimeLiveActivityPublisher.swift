import Foundation
import ActivityKit
import WidgetKit

/// Una identidad de estancia incluye ID, nombre, comienzo y tipo de seguimiento.
/// El nombre por sí solo no detecta la salida y regreso a una misma zona.
struct TimeActivityFingerprint:Equatable {
    let cellID:String
    let visibleName:String
    let startedAt:Date
    let resting:Bool
}

/// Una solicitud ActivityKit aceptada no implica que iOS dibuje la extensión.
@MainActor final class TimeLiveActivityPublisher {
    private var lastUpdated: Date = .distantPast
    private var lastFingerprint: TimeActivityFingerprint?
    private var refreshTask: Task<Void,Never>?


    func check(from model: TimeModel) {
        let enabled=ActivityAuthorizationInfo().areActivitiesEnabled
        let items=Activity<TimeMapActivityAttributes>.activities
        let states=items.map { "\($0.id.prefix(8)): \($0.activityState)" }.joined(separator:", ")
        model.liveActivityDiagnostic = "Permiso iOS: \(enabled ? "sí" : "no") · Solicitudes visibles a ActivityKit: \(items.count)" +
            (states.isEmpty ? "" : " · "+states)
        let plugIns=Bundle.main.builtInPlugInsURL
        let embedded=plugIns.map {
            FileManager.default.fileExists(atPath:$0.appendingPathComponent("MiMapaWidgets.appex").path)
        } ?? false
        let extensionURL=plugIns?.appendingPathComponent("MiMapaWidgets.appex")
        let extensionBundle=extensionURL.flatMap(Bundle.init(url:))
        let extensionID=extensionBundle?.bundleIdentifier ?? "sin ID"
        let extensionInfo=extensionBundle?.infoDictionary?["NSExtension"] as? [String:Any]
        let point=extensionInfo?["NSExtensionPointIdentifier"] as? String ?? "sin NSExtension"
        let appGroup=TimeWidgetStorage.isAvailable
        model.widgetDiagnostic=embedded ?
            "Extensión incluida · \(extensionID) · punto \(point). App Group: \(appGroup ? "autorizado" : "no disponible"). El alta en la galería depende de la firma de iOS." :
            "MiMapaWidgets.appex NO existe en la app instalada: comprobar cómo Sideloadly firma y empaqueta la extensión."
        WidgetCenter.shared.getCurrentConfigurations { result in
            Task { @MainActor in
                switch result {
                case .success(let widgets):
                    model.widgetDiagnostic += " Widgets añadidos al escritorio: \(widgets.count) (cero no significa que falte de la galería)."
                case .failure(let error):
                    model.widgetDiagnostic += " WidgetCenter: \(error.localizedDescription)"
                }
            }
        }
    }

    func test(from model: TimeModel) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            model.liveActivityDiagnostic="iOS rechaza Actividades en directo; comprueba permisos y restricciones."
            return
        }
        let state=TimeMapActivityAttributes.ContentState(
            cellName:"Prueba Mi Mapa",stayStartedAt:Date(),resting:false)
        let content=ActivityContent(state:state,staleDate:nil)
        model.liveActivityDiagnostic="Solicitando Actividad en directo de prueba…"
        Task {
            do {
                for item in Activity<TimeMapActivityAttributes>.activities {
                    await item.end(nil,dismissalPolicy:.immediate)
                }
                let activity=try Activity<TimeMapActivityAttributes>.request(
                    attributes:TimeMapActivityAttributes(),content:content,pushType:nil)
                model.liveActivityDiagnostic="ActivityKit aceptó la solicitud · ID \(activity.id.prefix(12)) · estado \(activity.activityState). Bloquea el iPhone para comprobar el panel; si no aparece, revisa la firma de la extensión."
            } catch {
                model.liveActivityDiagnostic="Fallo al crear Actividad en directo: \(String(reflecting:error))"
            }
        }
    }

    func refresh(from model: TimeModel, force: Bool = false, now: Date = .now) {
        let enabled=UserDefaults.standard.bool(forKey:"miMapaLiveActivity")
        let allowed=ActivityAuthorizationInfo().areActivitiesEnabled
        let activities=Activity<TimeMapActivityAttributes>.activities
        guard enabled,allowed,
              let cell=model.activeCell,
              let start=model.currentVisitStart ?? model.data.gpsRest?.startedAt,
              model.recording || model.isResting else {
            lastFingerprint=nil
            lastUpdated = .distantPast
            refreshTask?.cancel()
            refreshTask=nil
            if !activities.isEmpty {
                Task {
                    for activity in activities {
                        await activity.end(nil,dismissalPolicy:.immediate)
                    }
                }
            }
            return
        }
        let fingerprint=TimeActivityFingerprint(
            cellID:cell.id,visibleName:model.label(for:cell),
            startedAt:start,resting:model.isResting)
        guard force || lastFingerprint != fingerprint ||
              now.timeIntervalSince(lastUpdated) >= 120 else { return }
        lastUpdated=now
        lastFingerprint=fingerprint
        let content=ActivityContent(state:TimeMapActivityAttributes.ContentState(
            cellName:fingerprint.visibleName,stayStartedAt:fingerprint.startedAt,
            resting:fingerprint.resting),staleDate:nil)
        refreshTask?.cancel()
        refreshTask=Task {
            if let active=Activity<TimeMapActivityAttributes>.activities.first {
                await active.update(content)
                guard !Task.isCancelled else { return }
                model.liveActivityDiagnostic="Actividad actualizada · \(active.id.prefix(12)) · \(active.activityState)"
            } else {
                do {
                    let item=try Activity<TimeMapActivityAttributes>.request(
                        attributes:TimeMapActivityAttributes(),content:content,pushType:nil)
                    guard !Task.isCancelled else { return }
                    model.liveActivityDiagnostic="Actividad creada · \(item.id.prefix(12)) · \(item.activityState)"
                } catch {
                    guard !Task.isCancelled else { return }
                    lastFingerprint=nil  // permitir reintentar en la siguiente posición GPS
                    model.liveActivityDiagnostic="Error ActivityKit: \(String(reflecting:error))"
                }
            }
        }
    }

}
