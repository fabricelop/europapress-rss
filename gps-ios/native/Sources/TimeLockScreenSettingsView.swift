import SwiftUI

/// Controles y resultados técnicos separados de los Ajustes cotidianos.
struct TimeLockScreenSettingsView: View {
    @ObservedObject var model:TimeModel
    @AppStorage("miMapaLiveActivity") private var liveActivityEnabled = false
    @AppStorage("timeWidgetShowPlace") private var showPlace = false
    @State private var scriptableFile:URL?
    @State private var exportErrorMessage = ""

    var body: some View {
        Form {
            Section("Actividad en directo") {
                Toggle("Mostrar estancia en bloqueo",isOn:$liveActivityEnabled)
                    .onChange(of:liveActivityEnabled) { _,enabled in
                        model.setLockScreenEnabled(enabled)
                    }
                Button("Probar ahora") { model.testLiveActivity() }
                    .buttonStyle(.borderedProminent)
                Text(model.liveActivityDiagnostic)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Widget nativo") {
                LabeledContent("Contenedor de datos",value:
                    TimeWidgetStorage.isAvailable ? "Autorizado" : "No disponible con esta firma")
                Toggle("Mostrar nombres en widget",isOn:$showPlace)
                    .disabled(!TimeWidgetStorage.isAvailable)
                    .onChange(of:showPlace) { _,_ in model.refreshWidgets() }
                Button("Comprobar widgets y actividad") {
                    model.checkLockScreen()
                }
                Text(model.widgetDiagnostic)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Link("Diagnosticar en Windows (registros USB)",
                     destination:URL(string:"https://github.com/fabricelop/europapress-rss/blob/feature/mi-mapa-del-tiempo-ios-v12/gps-ios/native/DIAGNOSTICO-WINDOWS-LIVE-ACTIVITY.md")!)
                    .font(.caption)
            }
            Section("Alternativa Scriptable") {
                Button("Preparar resumen para Scriptable") {
                    do { scriptableFile=try model.exportScriptableSnapshot() }
                    catch { exportErrorMessage=error.localizedDescription }
                }
                if let scriptableFile {
                    ShareLink(item:scriptableFile) {
                        Label("Guardar MiMapaEstado.json en iCloud Drive",
                              systemImage:"square.and.arrow.up")
                    }
                }
                Text("Guarda MiMapaEstado.json en iCloud Drive/Scriptable y selecciona el script en el widget rectangular de Scriptable. El resumen debe exportarse otra vez para reflejar movimientos nuevos.")
                    .font(.caption).foregroundStyle(.secondary)
                if !exportErrorMessage.isEmpty { Text(exportErrorMessage).font(.caption).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Bloqueo y widgets")
        .onAppear { model.checkLockScreen() }
    }
}
