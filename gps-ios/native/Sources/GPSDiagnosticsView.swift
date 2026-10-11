import SwiftUI
import CoreLocation

struct GPSDiagnosticsView: View {
    @ObservedObject var model: TimeModel
    @ObservedObject var gps: GPSService

    var body: some View {
        List {
            Section("Seguimiento") {
                LabeledContent("Estado",value:model.gpsStatus)
                LabeledContent("Modo",value:"Continuo · sin pausa automática")
                LabeledContent("Pausas notificadas por iOS",value:String(gps.pauseCount))
                LabeledContent("Reanudaciones notificadas",value:String(gps.resumeCount))
                LabeledContent("Último hueco entre muestras",value:DurationFormat.full(gps.lastGapSeconds))
                LabeledContent("Core Motion",value:gps.motionAvailable ? "Disponible" : "No disponible")
                if let accuracy=model.lastAccuracy {
                    LabeledContent("Precisión de última muestra",
                                   value:String(format:"± %.0f m",accuracy))
                }
                if let last=model.lastGPSFix {
                    LabeledContent("Última muestra",value:last.formatted(date:.abbreviated,time:.standard))
                    TimelineView(.periodic(from:.now,by:1)) { context in
                        LabeledContent("Edad del GPS",value:"\(Int(max(0,context.date.timeIntervalSince(last)))) s")
                    }
                }
            }
            Section("Datos locales") {
                LabeledContent("Motor de almacenamiento",value:model.storeStatus)
                LabeledContent("Posiciones conservadas",value:String(model.retainedFixCount))
                LabeledContent("Intervalos asignados",value:String(model.data.intervals.count))
                LabeledContent("Tiempo sin atribución fiable",
                               value:DurationFormat.full(model.data.missingSeconds))
                LabeledContent("Cuadrículas visitadas",value:String(model.allCells.count))
            }
            Section("Continuidad GPS · eventos recientes") {
                if model.savedPowerEvents.isEmpty {
                    Text("Aún no hay registros de cambios de modo")
                } else {
                    ForEach(Array(model.savedPowerEvents.suffix(30).reversed())) { event in
                        VStack(alignment:.leading,spacing:3) {
                            HStack {
                                Text(event.mode).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(event.date.formatted(date:.abbreviated,time:.shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(event.cause).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Interpretación") {
                Text("Posiciones conservadas no equivale al número de posiciones recibidas. En estancias quietas se guardan menos muestras, pero las duraciones de las muestras recibidas se siguen asignando a sus cuadrículas.")
                Text("Los tramos sin muestras fiables se registran como incertidumbre, no como una estancia confirmada. CoreMotion es solo diagnóstico: no puede garantizar la reactivación de una app suspendida.")
                Text("Un iPhone puede limitar o detener la localización por permisos, falta de señal o cierre del proceso. Este diagnóstico no demuestra continuidad mientras el teléfono esté bloqueado.")
                Text("La migración inicial conserva el JSON previo y crea una nueva base SQLite. Exporta una copia JSON antes de actualizar o cambiar de dispositivo.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Diagnóstico GPS")
    }
}
