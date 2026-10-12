import SwiftUI
import WidgetKit
import ActivityKit

/// Comprobación en el iPhone final: GitHub CI sólo comprueba los binarios sin firmar.
struct TimeLockScreenSettingsView:View {
    @ObservedObject var model:TimeModel
    @AppStorage("miMapaLiveActivity") private var liveActivityEnabled=false
    @AppStorage("timeWidgetShowPlace") private var showPlace=false
     @State private var extensionDetails="Pendiente"
    private var appGroupOK:Bool { TimeWidgetStorage.isAvailable }

    var body:some View {
        Form {
            Section("Widget nativo") {
                LabeledContent("Compartición de datos",
                    value:appGroupOK ? "App Group autorizado" : "App Group no autorizado")
                if appGroupOK {
                    Toggle("Mostrar nombres en el widget",isOn:$showPlace)
                        .onChange(of:showPlace) { _,_ in model.refreshWidgets() }
                } else {
                    Label("El widget funciona como acceso al mapa. La firma instalada no autoriza compartir sus datos.",systemImage:"lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Actualizar widget y comprobar extensión") {
                    model.refreshWidgets()
                    model.checkLockScreen()
                    updateExtensionDetails()
                }
                LabeledContent("Extensión de WidgetKit",value:extensionDetails)
                Text(model.widgetDiagnostic)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Si el widget aparece en la galería pero el App Group está bloqueado, la extensión está registrada correctamente. No inventaremos cifras: se ofrece un acceso al mapa.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Actividad en directo · bloqueo") {
                Toggle("Mostrar estancia en el bloqueo",isOn:$liveActivityEnabled)
                    .onChange(of:liveActivityEnabled) { _,enabled in
                        model.setLockScreenEnabled(enabled)
                    }
                Button("Crear actividad de prueba") { model.testLiveActivity() }
                    .buttonStyle(.borderedProminent)
                Button("Comprobar solicitudes ActivityKit") {
                    model.checkLockScreen()
                }
                Text(model.liveActivityDiagnostic)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("La actividad muestra el lugar y el temporizador mediante ActivityKit, sin depender del App Group.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Cómo verificar en el dispositivo") {
                Text("1. Instala la actualización de Mi Mapa Prueba con Impactor conservando su identificador.\\n2. Busca «Mi Mapa Prueba» en Añadir widget.\\n3. Activa la actividad y bloquéalo.\\n4. Revisa los diagnósticos si hay un error.")
                    .font(.caption)
                Text("La autorización de App Groups se concede en la firma y los perfiles de iOS, no mediante un interruptor de la aplicación.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Widgets y bloqueo")
        .onAppear {
            model.checkLockScreen()
            updateExtensionDetails()
        }
    }

    private func updateExtensionDetails() {
        guard let path=Bundle.main.builtInPlugInsURL?.appendingPathComponent("MiMapaWidgets.appex"),
              let ext=Bundle(url:path),
              FileManager.default.fileExists(atPath:path.path) else {
            extensionDetails="No incorporada"
            return
        }
        let extensionInfo=ext.infoDictionary?["NSExtension"] as? [String:Any]
        let point=extensionInfo?["NSExtensionPointIdentifier"] as? String
        let validPoint=point == "com.apple.widgetkit-extension"
        extensionDetails=validPoint ?
            "Incluida · \(ext.bundleIdentifier ?? "ID desconocido")" :
            "Configuración de extensión incorrecta"
    }
}
