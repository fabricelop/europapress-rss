import SwiftUI
import MapKit
import CoreLocation

/// Muestra las posiciones realmente conocidas antes/después del hueco.
/// No traza una ruta ficticia entre ambas.
enum GPSGapMapLayout {
    static func region(_ gap:TimeGPSGapReview)->MKCoordinateRegion {
        let points=Grid.polygon(gap.previousCell)+Grid.polygon(gap.nextCell)
        let south=points.map(\.latitude).min() ?? 40.4
        let north=points.map(\.latitude).max() ?? 40.4
        let west=points.map(\.longitude).min() ?? -3.7
        let east=points.map(\.longitude).max() ?? -3.7
        return MKCoordinateRegion(
            center:CLLocationCoordinate2D(latitude:(north+south)/2,
                                          longitude:(east+west)/2),
            span:MKCoordinateSpan(latitudeDelta:max(0.003,(north-south)*1.9),
                                 longitudeDelta:max(0.003,(east-west)*1.9)))
    }
    static func distance(_ gap:TimeGPSGapReview)->CLLocationDistance {
        let a=Grid.center(gap.previousCell),b=Grid.center(gap.nextCell)
        return CLLocation(latitude:a.latitude,longitude:a.longitude)
            .distance(from:CLLocation(latitude:b.latitude,longitude:b.longitude))
    }
    static func distanceLabel(_ gap:TimeGPSGapReview)->String {
        let meters=distance(gap)
        if meters<1000 { return "\(Int(meters.rounded())) m" }
        return String(format:"%.1f km",meters/1000)
    }
}

/// Mini mapa. Solo abre detalle el botón que lo contiene, nunca descarta.
struct GPSGapMiniMap:View {
    let gap:TimeGPSGapReview
    var body:some View {
        Map(initialPosition:.region(GPSGapMapLayout.region(gap)),
            interactionModes:[]) {
            MapPolygon(coordinates:Grid.polygon(gap.previousCell))
                .foregroundStyle(.cyan.opacity(0.34))
                .stroke(.cyan,lineWidth:2.5)
            if gap.previousCell != gap.nextCell {
                MapPolygon(coordinates:Grid.polygon(gap.nextCell))
                    .foregroundStyle(.orange.opacity(0.32))
                    .stroke(.orange,lineWidth:2.5)
            }
            Annotation("Antes",coordinate:Grid.center(gap.previousCell)) {
                Text("A").font(.caption2.bold()).foregroundStyle(.black)
                    .frame(width:25,height:25)
                    .background(.cyan,in:Circle())
            }
            if gap.previousCell != gap.nextCell {
                Annotation("Después",coordinate:Grid.center(gap.nextCell)) {
                    Text("D").font(.caption2.bold()).foregroundStyle(.black)
                        .frame(width:25,height:25)
                        .background(.orange,in:Circle())
                }
            }
        }
        .mapStyle(.standard(elevation:.flat))
        .frame(height:165)
        .clipShape(RoundedRectangle(cornerRadius:12))
        .allowsHitTesting(false)
        .accessibilityLabel("Mapa de cuadrículas: antes y después del hueco GPS")
    }
}

/// El mapa grande permite mover/zoom sin modificar el historial.
/// Ninguna pulsación sobre el mapa ejecuta acciones destructivas.
struct GPSGapMapDetail:View {
    @ObservedObject var model:TimeModel
    let gap:TimeGPSGapReview
    @Environment(\.dismiss) private var dismiss
    @State private var camera:MapCameraPosition = .automatic
    @State private var selection:TimeGPSGapChoice?
    @State private var showAssignConfirmation=false
    @State private var showDismissConfirmation=false
    @State private var resultMessage=""

    private var alreadyDismissed:Bool {
        model.data.dismissedGPSGapIDs.contains(gap.id)
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:15) {
                    Map(position:$camera) {
                        MapPolygon(coordinates:Grid.polygon(gap.previousCell))
                            .foregroundStyle(.cyan.opacity(0.26))
                            .stroke(.cyan,lineWidth:3)
                        if gap.previousCell != gap.nextCell {
                            MapPolygon(coordinates:Grid.polygon(gap.nextCell))
                                .foregroundStyle(.orange.opacity(0.26))
                                .stroke(.orange,lineWidth:3)
                        }
                        Annotation("Cuadrícula anterior",
                                   coordinate:Grid.center(gap.previousCell)) {
                            Label("ANTES",systemImage:"location.fill")
                                .font(.caption.bold())
                                .padding(8)
                                .foregroundStyle(.black)
                                .background(.cyan,in:Capsule())
                        }
                        if gap.previousCell != gap.nextCell {
                            Annotation("Cuadrícula posterior",
                                       coordinate:Grid.center(gap.nextCell)) {
                                Label("DESPUÉS",systemImage:"location.fill")
                                    .font(.caption.bold())
                                    .padding(8)
                                    .foregroundStyle(.black)
                                    .background(.orange,in:Capsule())
                            }
                        }
                    }
                    .mapStyle(.standard(elevation:.flat))
                    .mapControls { MapCompass() }
                    .frame(height:360)
                    .clipShape(RoundedRectangle(cornerRadius:14))
                    .onAppear { camera = .region(GPSGapMapLayout.region(gap)) }
                    HStack(spacing:12) {
                        Label("Antes",systemImage:"square.fill").foregroundStyle(.cyan)
                        if !gap.sameCell {
                            Label("Después",systemImage:"square.fill")
                                .foregroundStyle(.orange)
                        }
                        Spacer(minLength:3)
                        if gap.sameCell {
                            Text("Misma cuadrícula").font(.caption)
                        } else {
                            Text("Separación: \(GPSGapMapLayout.distanceLabel(gap))")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .font(.caption.weight(.medium))
                    VStack(alignment:.leading,spacing:7) {
                        Text(gap.start.formatted(.dateTime.weekday(.wide).day().month().year()
                            .locale(Locale(identifier:"es_ES"))))
                            .font(.headline)
                        Text("\(gap.start.formatted(.dateTime.hour().minute())) – \(gap.end.formatted(.dateTime.hour().minute())) · \(DurationFormat.full(gap.seconds)) sin datos")
                            .font(.subheadline)
                        Text("Antes: \(model.label(for:gap.previousCell))")
                        Text("Después: \(model.label(for:gap.nextCell))")
                        Text("El mapa muestra las dos cuadrículas conocidas, NO un trayecto registrado dentro del hueco.")
                            .font(.caption).foregroundStyle(.secondary)
                        if gap.contradictoryGPS {
                            Label("Existen posiciones contradictorias: no se permite asignar el hueco completo.",
                                  systemImage:"exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.caption)
                        }
                    }
                    if !resultMessage.isEmpty {
                        Text(resultMessage)
                            .font(.callout)
                            .foregroundStyle(.teal)
                    }
                    if gap.canManuallyAssign && !alreadyDismissed {
                        VStack(alignment:.leading,spacing:10) {
                            Text("¿Dónde permaneciste?").font(.headline)
                            Button("Asignar todo al lugar anterior") { choose(.previous) }
                            .buttonStyle(.borderedProminent).tint(.cyan)
                            if !gap.sameCell {
                                Button("Asignar todo al lugar siguiente") { choose(.next) }
                                    .buttonStyle(.bordered)
                                Button("Repartir mitad en cada cuadrícula") {
                                    choose(.splitEqually)
                                }.buttonStyle(.bordered)
                            }
                        }
                    }
                    if alreadyDismissed {
                        Button("Recuperar esta sugerencia") {
                            if model.restoreReviewedGap(gap) {
                                resultMessage="Sugerencia recuperada; puedes volver a revisarla."
                            } else {
                                resultMessage="No se pudo recuperar la sugerencia."
                            }
                        }.buttonStyle(.bordered)
                    } else {
                        Button("Descartar esta sugerencia",role:.destructive) {
                            showDismissConfirmation=true
                        }.buttonStyle(.bordered)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Mapa del hueco GPS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .alert("Confirmar tiempo estimado",isPresented:$showAssignConfirmation) {
                Button("Añadir tiempo") {
                    if let selection {
                        let result=model.confirmReviewedGap(gap,choice:selection)
                        resultMessage=result.message
                        if result.isSuccess { dismiss() }
                    }
                    selection=nil
                }
                Button("Cancelar",role:.cancel) { selection=nil }
            } message: {
                Text("Se asignarán \(DurationFormat.full(gap.seconds)) como estancia estimada. El GPS observado no se modificará.")
            }
            .confirmationDialog("¿Descartar esta sugerencia?",
                isPresented:$showDismissConfirmation,titleVisibility:.visible) {
                Button("Descartar sugerencia",role:.destructive) {
                    if model.dismissReviewedGap(gap) {
                        dismiss()
                    } else {
                        resultMessage="No se pudo guardar el descarte."
                    }
                }
                Button("Cancelar",role:.cancel) {}
            } message: {
                Text("Esto solo oculta la sugerencia. No borra ubicaciones ni tiempo registrado.")
            }
        }
    }
    private func choose(_ value:TimeGPSGapChoice) {
        selection=value
        showAssignConfirmation=true
    }
}
