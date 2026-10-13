import SwiftUI

/// Revisión global de huecos. Las estimaciones requieren una elección
/// consciente; nunca son sumadas como localizaciones GPS observadas.
struct GPSGapReviewView:View {
    @ObservedObject var model:TimeModel
    @State private var pendingGap:TimeGPSGapReview?
    @State private var pendingChoice:TimeGPSGapChoice?
    @State private var confirmOpen=false
    @State private var message=""
    @State private var showDismissed=false

    private var gaps:[TimeGPSGapReview] {
        TimeGPSGapReviewIndex.scan(
            intervals:model.data.intervals,fixes:model.data.fixes,
            events:model.data.powerEvents,
            dismissed:showDismissed ? [] : Set(model.data.dismissedGPSGapIDs))
    }
    private var total:TimeInterval { gaps.reduce(0){$0+$1.seconds} }

    var body:some View {
        List {
            Section {
                LabeledContent("Huecos pendientes",value:"\(gaps.count)")
                LabeledContent("Tiempo sin atribuir",value:DurationFormat.full(total))
                Text("Solo se enumeran huecos entre tramos del historial, sin tiempo asignado. Ninguna propuesta añade segundos hasta que la confirmas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                Section {
                    Text(message).font(.caption)
                        .foregroundStyle(.teal)
                        .accessibilityIdentifier("gpsGapReviewFeedback")
                }
            }
            if gaps.isEmpty {
                Section {
                    ContentUnavailableView("Sin huecos pendientes",
                        systemImage:"checkmark.shield",
                        description:Text("No hay interrupciones de más de tres minutos por revisar entre los registros disponibles."))
                }
            } else {
                Section("Intervalos del historial") {
                    ForEach(gaps) { gap in
                        VStack(alignment:.leading,spacing:9) {
                            HStack {
                                Text(gap.start.formatted(.dateTime.day().month().year()))
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(DurationFormat.full(gap.seconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                            HStack(spacing:7) {
                                Image(systemName:"clock.arrow.circlepath")
                                Text("\(localClock(gap.start)) – \(localClock(gap.end))")
                            }
                            .font(.subheadline)
                            VStack(alignment:.leading,spacing:4) {
                                Text("Antes: \(model.label(for:gap.previousCell))")
                                Text("Después: \(model.label(for:gap.nextCell))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Label(gap.highConfidence ?
                                "Misma cuadrícula · GPS fiable en ambos extremos" :
                                gap.sameCell ?
                                "Misma cuadrícula · requiere confirmación manual" :
                                "Dos cuadrículas distintas · indica dónde estuviste",
                                systemImage:gap.highConfidence ?
                                    "location.circle.fill" : "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(gap.highConfidence ? Color.teal : Color.orange)
                            if gap.trackingWasStopped {
                                Text("El seguimiento estuvo detenido durante este intervalo.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if gap.contradictoryGPS {
                                Text("Hay una posición GPS fiable contradictoria en el hueco. No se permite asignar automáticamente el intervalo completo.")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            if gap.canManuallyAssign && !showDismissed {
                                if gap.sameCell {
                                    Button("Confirmar estancia aquí") {
                                        prepare(gap,.previous)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.teal)
                                } else {
                                    HStack(spacing:8) {
                                        Button("Lugar anterior") { prepare(gap,.previous) }
                                        Button("Lugar siguiente") { prepare(gap,.next) }
                                    }
                                    .buttonStyle(.bordered)
                                    Button("Repartir mitad en cada cuadrícula") {
                                        prepare(gap,.splitEqually)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                }
                            } else if gap.seconds>86400 {
                                Text("Hueco de más de un día: requiere revisión por periodos más pequeños para evitar atribuciones masivas.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if !showDismissed {
                                Button("Descartar esta sugerencia",role:.destructive) {
                                    let saved=model.dismissReviewedGap(gap)
                                    message=saved ? "Hueco descartado sin modificar el historial." :
                                        "No se pudo guardar el descarte. Revisa Ajustes → Estado técnico."
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical,4)
                    }
                }
            }
            if !model.data.dismissedGPSGapIDs.isEmpty {
                Section("Sugerencias descartadas") {
                    Toggle("Ver también las descartadas",isOn:$showDismissed)
                    Button("Reactivar todos los descartes") {
                        model.restoreDismissedGPSGaps()
                        showDismissed=false
                    }
                }
            }
            Section {
                Text("Los huecos sin GPS nunca se suman automáticamente. Al confirmar, la duración se guarda como «asumido · confirmado por usuario». Los trayectos y posiciones originales se conservan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Huecos GPS")
        .navigationBarTitleDisplayMode(.inline)
        .alert("¿Dónde permaneciste durante el hueco?",
               isPresented:$confirmOpen) {
            Button("Añadir tiempo estimado") {
                if let gap=pendingGap,let choice=pendingChoice {
                    let result=model.confirmReviewedGap(gap,choice:choice)
                    message=result.message
                }
                pendingGap=nil
                pendingChoice=nil
            }
            Button("Cancelar",role:.cancel) {
                pendingGap=nil
                pendingChoice=nil
            }
        } message: {
            if let pendingGap,let pendingChoice {
                Text("Asignar \(DurationFormat.full(pendingGap.seconds)) como tiempo estimado: \(description(pendingGap,pendingChoice)). No se considerará GPS observado.")
            }
        }
    }

    private func description(_ gap:TimeGPSGapReview,_ choice:TimeGPSGapChoice)->String {
        switch choice {
        case .previous: return model.label(for:gap.previousCell)
        case .next: return model.label(for:gap.nextCell)
        case .splitEqually: return "mitad en \(model.label(for:gap.previousCell)) y mitad en \(model.label(for:gap.nextCell))"
        }
    }
    private func localClock(_ date:Date)->String {
        date.formatted(.dateTime.hour().minute())
    }
    private func prepare(_ gap:TimeGPSGapReview,_ choice:TimeGPSGapChoice) {
        pendingGap=gap
        pendingChoice=choice
        confirmOpen=true
    }
}
