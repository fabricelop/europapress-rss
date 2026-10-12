import Foundation
import ActivityKit
import WidgetKit

/// Nunca ocultar fallos de ActivityKit: una solicitud aceptada tampoco
/// garantiza que iOS renderice la extensión firmada por Sideloadly.
@MainActor final class TimeLiveActivityPublisher {
    private var lastUpdated: Date = .distantPast
    private var lastName: String?
    private var lastResting: Bool?

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
        let activities=Activity<TimeMapActivityAttributes>.activities
        guard enabled,ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !activities.isEmpty {
                Task { for activity in activities {
                    await activity.end(nil,dismissalPolicy:.immediate)
                } }
            }
            return
        }
        guard let cell=model.activeCell,
              let start=model.currentVisitStart ?? model.data.gpsRest?.startedAt,
              model.recording || model.isResting else { return }
        let name=model.label(for:cell), resting=model.isResting
        let changed=lastName != name || lastResting != resting
        guard force || changed || now.timeIntervalSince(lastUpdated) >= 120 else { return }
        lastUpdated=now; lastName=name; lastResting=resting
        let state=TimeMapActivityAttributes.ContentState(
            cellName:name,stayStartedAt:start,resting:resting)
        let content=ActivityContent(state:state,staleDate:nil)
        Task {
            if let active=Activity<TimeMapActivityAttributes>.activities.first {
                await active.update(content)
                model.liveActivityDiagnostic="Actividad actualizada · \(active.id.prefix(12)) · \(active.activityState)"
            } else {
                do {
                    let item=try Activity<TimeMapActivityAttributes>.request(
                        attributes:TimeMapActivityAttributes(),content:content,pushType:nil)
                    model.liveActivityDiagnostic="Actividad creada · \(item.id.prefix(12)) · \(item.activityState)"
                } catch {
                    model.liveActivityDiagnostic="Error ActivityKit: \(String(reflecting:error))"
                }
            }
        }
    }
}
