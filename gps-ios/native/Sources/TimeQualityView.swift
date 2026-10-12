import SwiftUI

struct TimeQualityView: View {
    @ObservedObject var model:TimeModel

    private var values:TimeQualitySummary {
        TimeQualitySummary.calculate(model.data.intervals,missing:model.data.missingSeconds)
    }

    var body: some View {
        List {
            Section("Tiempo histórico") {
                LabeledContent("Asignado sin solapamientos",
                               value:DurationFormat.full(values.assigned))
                LabeledContent("Observado entre muestras GPS",
                               value:DurationFormat.full(values.observed))
                LabeledContent("Reconstruido entre puntos",
                               value:DurationFormat.full(values.reconstructed))
            }
            Section("Comprobaciones") {
                LabeledContent("Solapamiento detectado en datos originales",
                               value:DurationFormat.full(values.overlapSeconds))
                LabeledContent("Intervalos originales",
                               value:String(model.data.intervals.count))
                LabeledContent("Cuadrículas conocidas",
                               value:String(model.allCells.count))
                Text("Las estadísticas utilizan una vista de intervalos sin duplicar segundos. Los intervalos originales se conservan intactos para poder auditar los datos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cómo interpretar estos datos") {
                Text("Observado: tiempo atribuido entre muestras GPS cercanas y coherentes; no equivale a una ubicación verificada cada segundo.")
                Text("Reconstruido: reparto de tiempo entre muestras con desplazamiento compatible; su geometría intermedia es estimada.")
                Text("Un porcentaje alto de tiempo observado no permite garantizar que iOS registrara cada esquina del trayecto ni atribuir toda la batería a esta aplicación.")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Calidad del historial")
    }
}
