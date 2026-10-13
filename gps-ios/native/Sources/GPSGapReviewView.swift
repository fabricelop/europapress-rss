import SwiftUI

/// Revisión de tiempo sin GPS. Tocar una tarjeta SOLO abre el mapa.
/// Descartar exige el botón y una segunda confirmación explícita.
struct GPSGapReviewView:View {
    @ObservedObject var model:TimeModel
    @State private var pendingGap:TimeGPSGapReview?
    @State private var pendingChoice:TimeGPSGapChoice?
    @State private var confirmOpen=false
    @State private var pendingDismissGap:TimeGPSGapReview?
    @State private var showDismissConfirmation=false
    @State private var selectedMapGap:TimeGPSGapReview?
    @State private var openRouteEditor=false
    @State private var message=""
    @State private var showDismissed=false

    private var gaps:[TimeGPSGapReview] {
        TimeGPSGapReviewIndex.scan(
            intervals:model.data.intervals,fixes:model.data.fixes,
            events:model.data.powerEvents,
            dismissed:showDismissed ? [] : Set(model.data.dismissedGPSGapIDs))
    }
    private var pendingCount:Int {
        gaps.filter { !model.data.dismissedGPSGapIDs.contains($0.id) }.count
    }
    private var total:TimeInterval {
        gaps.filter { !model.data.dismissedGPSGapIDs.contains($0.id) }
            .reduce(0) { $0+$1.seconds }
    }

    var body:some View {
        List {
            Section {
                LabeledContent("Huecos pendientes",value:"\(pendingCount)")
                LabeledContent("Tiempo sin atribuir",value:DurationFormat.full(total))
                Text("Toca una tarjeta o su minimapa para ver las cuadrículas antes y después. Ningún toque fuera de los botones modifica el historial.")
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
                        gapRow(gap)
                    }
                }
            }
            if !model.data.dismissedGPSGapIDs.isEmpty {
                Section("Sugerencias descartadas") {
                    Toggle("Ver también las descartadas",isOn:$showDismissed)
                    Button("Reactivar todos los descartes") {
                        model.restoreDismissedGPSGaps()
                        showDismissed=false
                        message="Se han reactivado las sugerencias descartadas."
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section {
                Text("Los huecos sin GPS nunca se suman automáticamente. Al confirmar, la duración se guarda como «asumido · confirmado por usuario». El mapa solo muestra las posiciones conocidas, no un recorrido inventado.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Huecos GPS")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item:$selectedMapGap) { gap in
            GPSGapMapDetail(model:model,gap:gap,
                            startRouteEditor:openRouteEditor)
        }
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
        .confirmationDialog("¿Descartar esta sugerencia?",
            isPresented:$showDismissConfirmation,titleVisibility:.visible) {
            Button("Descartar sugerencia",role:.destructive) {
                if let gap=pendingDismissGap {
                    let saved=model.dismissReviewedGap(gap)
                    message=saved ?
                        "Sugerencia descartada. Puedes recuperarla en «Ver también las descartadas»." :
                        "No se pudo guardar el descarte. Revisa Ajustes → Estado técnico."
                }
                pendingDismissGap=nil
            }
            Button("Cancelar",role:.cancel) { pendingDismissGap=nil }
        } message: {
            Text("Solo se ocultará esta propuesta. No se borrará ninguna ubicación ni se perderá tiempo del historial.")
        }
    }

    private func gapRow(_ gap:TimeGPSGapReview)->some View {
        let dismissed=model.data.dismissedGPSGapIDs.contains(gap.id)
        return VStack(alignment:.leading,spacing:11) {
            // Button explícito, estilo plain: el resto de los botones no
            // heredan la zona táctil de toda la fila List.
            Button {
                openRouteEditor=false
                selectedMapGap=gap
            } label: {
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
                    }.font(.subheadline)
                    GPSGapMiniMap(gap:gap)
                    HStack {
                        Text("A: \(model.label(for:gap.previousCell))")
                        Spacer(minLength:7)
                        Text("D: \(model.label(for:gap.nextCell))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    if !gap.sameCell {
                        Text("Separación de cuadrículas: \(GPSGapMapLayout.distanceLabel(gap))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing:5) {
                        Image(systemName:gap.highConfidence ?
                              "location.circle.fill" : "exclamationmark.circle")
                        Text(gap.highConfidence ?
                            "Misma cuadrícula · GPS fiable en ambos extremos" :
                            gap.sameCell ? "Misma cuadrícula · revisar la permanencia" :
                            "Dos cuadrículas distintas · consulta el mapa")
                    }
                    .font(.caption)
                    .foregroundStyle(gap.highConfidence ? Color.teal : Color.orange)
                    Label("Ver detalle y mapa ampliable",
                          systemImage:"map")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.teal)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gpsGapOpenMap")
            if gap.trackingWasStopped {
                Text("El seguimiento estuvo detenido durante este intervalo.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if gap.contradictoryGPS {
                Text("Hay una posición GPS fiable contradictoria: no se permite asignar el intervalo completo.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if dismissed {
                Label("Sugerencia descartada",systemImage:"eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Recuperar esta sugerencia") {
                    let restored=model.restoreReviewedGap(gap)
                    message=restored ? "Sugerencia recuperada." :
                        "No se pudo recuperar la sugerencia."
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("gpsGapRestore")
            } else {
                if gap.canManuallyAssign {
                    if gap.sameCell {
                        Button("Confirmar estancia aquí") { prepare(gap,.previous) }
                            .buttonStyle(.borderedProminent).tint(.teal)
                    } else {
                        HStack(spacing:8) {
                            Button("Lugar anterior") { prepare(gap,.previous) }
                            Button("Lugar siguiente") { prepare(gap,.next) }
                        }
                        .buttonStyle(.bordered)
                        Button("Repartir mitad en cada cuadrícula") {
                            prepare(gap,.splitEqually)
                        }.font(.caption).buttonStyle(.bordered)
                        Button {
                            openRouteEditor=true
                            selectedMapGap=gap
                        } label: {
                            Label("Repartir por recorrido en mapa",
                                  systemImage:"point.topleft.down.to.point.bottomright.curvepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .accessibilityIdentifier("gpsGapEditEstimatedRoute")
                    }
                } else if gap.seconds>86400 {
                    Text("Hueco de más de un día: requiere revisión por periodos más pequeños.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Descartar esta sugerencia",role:.destructive) {
                    pendingDismissGap=gap
                    showDismissConfirmation=true
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("gpsGapRequestDismiss")
            }
        }
        .padding(.vertical,7)
    }

    private func description(_ gap:TimeGPSGapReview,_ choice:TimeGPSGapChoice)->String {
        switch choice {
        case .previous: return model.label(for:gap.previousCell)
        case .next: return model.label(for:gap.nextCell)
        case .splitEqually:
            return "mitad en \(model.label(for:gap.previousCell)) y mitad en \(model.label(for:gap.nextCell))"
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
