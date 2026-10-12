import SwiftUI
import WidgetKit
import ActivityKit

@main
struct WidgetProbeApp:App {
    var body:some Scene {
        WindowGroup { WidgetProbeHome() }
    }
}
struct WidgetProbeHome:View {
    @State private var info="Pulsa comprobar."
    @State private var activityResult=""
    var body:some View {
        NavigationStack {
            Form {
                Section("Widget estático, sin App Group") {
                    Text("Busca «Diagnóstico Widget» en la galería de widgets. Debe mostrar WIDGET OK aunque no compartamos ningún dato.")
                    Button("Comprobar instalación") { inspect() }
                    Text(info).font(.caption).textSelection(.enabled)
                }
                Section("Actividad en directo, sin datos externos") {
                    Button("Crear actividad de prueba") { createActivity() }
                        .buttonStyle(.borderedProminent)
                    Text(activityResult).font(.caption).textSelection(.enabled)
                }
                Section("Cómo interpretar") {
                    Text("Si esta app tampoco aparece en la galería, revisaremos la firma de la extensión en Sideloadly, no el App Group de Mi Mapa.")
                    Text("Si el widget aparece, podremos corregir la app principal sin cambiar tu instalación.")
                    Text("Este diagnóstico NO modifica ni contiene tus ubicaciones.")
                }
            }
            .navigationTitle("Diagnóstico Widget")
        }
        .onAppear { inspect() }
    }
    private func inspect() {
        let url=Bundle.main.builtInPlugInsURL?.appendingPathComponent("WidgetProbeExtension.appex")
        let bundle=url.flatMap(Bundle.init(url:))
        let ext=bundle?.infoDictionary?["NSExtension"] as? [String:Any]
        let point=ext?["NSExtensionPointIdentifier"] as? String ?? "NO"
        let enabled=ActivityAuthorizationInfo().areActivitiesEnabled
        let count=Activity<ProbeActivityAttributes>.activities.count
        info="Extensión: \(bundle?.bundleIdentifier ?? "NO INSTALADA") · NSExtension: \(point) · ActivityKit permitido: \(enabled) · actividades: \(count)"
        WidgetCenter.shared.getCurrentConfigurations { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let widgets):
                    info += " · Widgets añadidos: \(widgets.count). El cero no permite saber si está en la galería."
                case .failure(let error):
                    info += " · WidgetCenter error: \(error.localizedDescription)"
                }
            }
        }
    }
    private func createActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            activityResult="ActivityKit rechazado por permisos de iOS."
            return
        }
        let state=ProbeActivityAttributes.ContentState(caption:"Prueba de bloqueo",startedAt:.now)
        do {
            let item=try Activity<ProbeActivityAttributes>.request(
                attributes:ProbeActivityAttributes(),
                content:ActivityContent(state:state,staleDate:nil),
                pushType:nil)
            activityResult="ID \(item.id) · estado \(item.activityState). Bloquea iPhone y comprueba si aparece ACTIVITY OK."
        } catch {
            activityResult="Error: \(String(reflecting:error))"
        }
    }
}
