import SwiftUI
import ActivityKit

/// Configuración exclusivamente de ActivityKit. El widget de inicio y sus
/// opciones de App Group se han retirado de la app.
struct TimeLiveSettingsView:View {
    @ObservedObject var model:TimeModel
    @AppStorage("miMapaLiveActivity") private var enabled=false

    var body:some View {
        Form {
            Section("Actividad en directo") {
                Toggle("Mostrar estancia en el bloqueo",isOn:$enabled)
                    .onChange(of:enabled) { _,value in
                        model.setLockScreenEnabled(value)
                    }
                Button {
                    model.reactivateLiveActivity()
                    enabled=true
                } label: {
                    Label("Reactivar En vivo ahora",systemImage:"arrow.clockwise.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("Comprobar estado de ActivityKit") {
                    model.checkLockScreen()
                }
                Text(model.liveActivityDiagnostic)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("Qué se muestra") {
                Label("Lugar y tiempo de estancia",systemImage:"clock")
                Label("Total confirmado en cuadrícula y zona",systemImage:"hourglass")
                Label("Minimapa esquemático 3×3",systemImage:"square.grid.3x3")
                Label("Permanencia confirmada en las últimas 6 horas",
                      systemImage:"chart.bar.fill")
                Text("El gráfico usa las posiciones ya registradas. No añade tiempo provisional. Si el GPS deja de informar, el reloj queda limitado y la actividad indica que sus datos están desactualizados.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recuperación") {
                Text("Al volver a abrir el mapa se recupera la actividad si iOS la terminó. También puedes tocar «En vivo» en el mapa o el botón de arriba. Si todavía no existe una posición GPS actual, comenzará con la próxima muestra válida.")
                    .font(.caption)
                Text("iOS controla la duración y el tamaño de las actividades en directo. Esta función no necesita widgets del escritorio ni App Groups.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("En vivo")
        .onAppear { model.checkLockScreen() }
    }
}
