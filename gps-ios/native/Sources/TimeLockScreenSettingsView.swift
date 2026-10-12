import SwiftUI
import WidgetKit
import ActivityKit

/// Comprobación en el iPhone final: GitHub CI sólo comprueba los binarios sin firmar.
struct TimeLockScreenSettingsView:View {
    @ObservedObject var model:TimeModel
    @AppStorage("miMapaLiveActivity") private var liveActivityEnabled=false
    @AppStorage("timeWidgetShowPlace") private var showPlace=false
    @State private var actualGalleryResult=""
    @State private var actualActivityResult=""
    @State private var extensionDetails="Pendiente"
    private var appGroupOK:Bool { TimeWidgetStorage.isAvailable }

    var body:some View {
        Form {
            Section("Widget nativo") {
                LabeledContent("Compartición de datos",
                    value:appGroupOK ? "App Group autorizado" : "App Group no autorizado")
                Toggle("Mostrar nombres en el widget",isOn:$showPlace)
                    .disabled(!appGroupOK)
                    .onChange(of:showPlace) { _,_ in model.refreshWidgets() }
                Button("Actualizar widget y comprobar extensión") {
                    model.refreshWidgets()
                    model.checkLockScreen()
                    updateExtensionDetails()
                }
                LabeledContent("Extensión de WidgetKit",value:extensionDetails)
                Text(model.widgetDiagnostic)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("La galería depende del registro de la extensión en iOS. Un App Group sin autorización impide compartir los datos, pero no prueba por sí solo que falte de la galería.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("En mi iPhone NO aparece en la galería") {
                    actualGalleryResult="No visible. Revisar firma individual de MiMapaWidgets.appex, identificador de equipo y perfiles de app + extensión en Sideloadly. Prueba tras reinstalar firmando ambas."
                }
                if !actualGalleryResult.isEmpty {
                    Text(actualGalleryResult).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
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
                Button("La actividad NO aparece al bloquear el iPhone") {
                    actualActivityResult="Si ActivityKit acepta la solicitud pero no se ve, comprobar Ajustes de iOS → app → Actividades en directo y la firma de la extensión WidgetKit. La confirmación definitiva exige prueba con pantalla bloqueada en iPhone."
                }
                if !actualActivityResult.isEmpty {
                    Text(actualActivityResult).font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Section("Cómo verificar en el dispositivo") {
                Text("1. Reinstala el IPA asegurando la firma de la app y MiMapaWidgets.appex.\n2. Abre la app y pulsa «Actualizar widget y comprobar extensión».\n3. Mantén pulsado el escritorio, pulsa Añadir widget y busca «Mi Mapa del Tiempo».\n4. En esta pantalla crea la actividad de prueba y bloquea el iPhone.\n5. Comprueba que iOS permite Actividades en directo.\n6. Si falla, copia el diagnóstico de esta pantalla.")
                    .font(.caption)
                Text("Con una cuenta gratuita, iOS puede rechazar el App Group o la extensión firmada. La presencia de un IPA compilado no demuestra que los permisos sobrevivan a Sideloadly.")
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
        let point=(ext.infoDictionary?["NSExtension"] as? [String:Any])?["NSExtensionPointIdentifier"] as? String
        let validPoint=point == "com.apple.widgetkit-extension"
        extensionDetails=validPoint ?
            "Incluida · \(ext.bundleIdentifier ?? "ID desconocido")" :
            "Configuración de extensión incorrecta"
    }
}
