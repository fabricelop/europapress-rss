import SwiftUI
import CoreLocation

struct GPSDiagnosticsView: View {
    @ObservedObject var model: TimeModel
    @ObservedObject var gps: GPSService

    var body: some View {
        List {
            Section("Seguimiento") {
                LabeledContent("Estado",value:model.gpsStatus)
                LabeledContent("Modo",value:model.isResting ? "Pausa voluntaria (tiempo asumido)" :
                               (model.recording ? "GPS continuo" : "GPS detenido"))
                LabeledContent("Última transición de pausa",
                               value:gps.lastPauseTransition)
                LabeledContent("Reactivaciones automáticas tras pausa",value:String(gps.automaticRestResumptions))
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
                if let backupDate = model.mostRecentLocalBackup {
                    LabeledContent("Última copia automática local",
                                   value:backupDate.formatted(date:.abbreviated,time:.shortened))
                } else {
                    LabeledContent("Copia automática local",value:"Aún no disponible")
                }
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
                Text("Los intervalos de pausa manual se atribuyen a la última cuadrícula como tiempo asumido, diferenciados del GPS observado. Las interrupciones involuntarias del GPS siguen sin reconstruirse.")
                Text("Los avisos de salida de región pueden reactivar el GPS si iOS permite la ejecución y está concedida la ubicación Siempre. No se garantiza una detección inmediata.")
                Text("Un iPhone puede limitar o detener la localización por permisos, falta de señal o cierre del proceso. Este diagnóstico no demuestra continuidad mientras el teléfono esté bloqueado.")
                Text("La migración inicial conserva el JSON previo y crea una nueva base SQLite. Exporta una copia JSON antes de actualizar o cambiar de dispositivo.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Diagnóstico GPS")
    }
}
