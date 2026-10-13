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
    var startRouteEditor:Bool=false
    @Environment(\.dismiss) private var dismiss
    @State private var camera:MapCameraPosition = .automatic
    @State private var selection:TimeGPSGapChoice?
    @State private var showAssignConfirmation=false
    @State private var showDismissConfirmation=false
    @State private var resultMessage=""
    @State private var routeMode=false
    @State private var addingWaypoints=false
    @State private var waypoints:[CLLocationCoordinate2D]=[]
    @State private var showRouteConfirmation=false
    private var routeEndpoints:[CLLocationCoordinate2D] {
        GPSGapRoutePlanner.endpoints(gap,fixes:model.data.fixes)
    }
    private var routePlan:GPSGapRoutePlan? {
        GPSGapRoutePlanner.preview(gap:gap,endpoints:routeEndpoints,via:waypoints)
    }

    private var alreadyDismissed:Bool {
        model.data.dismissedGPSGapIDs.contains(gap.id)
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:15) {
                    MapReader { reader in
                        Map(position:$camera) {
                        MapPolygon(coordinates:Grid.polygon(gap.previousCell))
                            .foregroundStyle(.cyan.opacity(0.26))
                            .stroke(.cyan,lineWidth:3)
                        if gap.previousCell != gap.nextCell {
                            MapPolygon(coordinates:Grid.polygon(gap.nextCell))
                                .foregroundStyle(.orange.opacity(0.26))
                                .stroke(.orange,lineWidth:3)
                        }
                        if routeMode,let routePlan {
                            // Es una hipótesis, no la trayectoria observada.
                            MapPolyline(coordinates:routePlan.coordinates)
                                .stroke(.yellow,lineWidth:5)
                            ForEach(routePlan.cells,id:\.id) { cell in
                                MapPolygon(coordinates:Grid.polygon(cell))
                                    .foregroundStyle(.yellow.opacity(0.16))
                                    .stroke(.yellow.opacity(0.55),lineWidth:1.5)
                            }
                            ForEach(Array(waypoints.enumerated()),id:\.offset) { index,coord in
                                Annotation("Paso \(index+1)",coordinate:coord) {
                                    Text("\(index+1)")
                                        .font(.caption2.bold())
                                        .padding(7)
                                        .foregroundStyle(.black)
                                        .background(.yellow,in:Circle())
                                }
                            }
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
                        .onTapGesture { screenPoint in
                            guard routeMode && addingWaypoints,
                                  waypoints.count<GPSGapRoutePlanner.maxWaypoints,
                                  let coordinate=reader.convert(screenPoint,from:.local)
                            else { return }
                            waypoints.append(coordinate)
                        }
                    }
                    .onAppear {
                        camera = .region(GPSGapMapLayout.region(gap))
                        routeMode = startRouteEditor
                    }
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
                    if gap.previousCell != gap.nextCell && !alreadyDismissed {
                        routeEditor
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
            .alert("Confirmar reparto geográfico estimado",
                   isPresented:$showRouteConfirmation) {
                Button("Guardar reparto estimado") {
                    if let plan=routePlan {
                        let result=model.confirmEstimatedRoute(gap,plan:plan)
                        resultMessage=result.message
                        if result.isSuccess { dismiss() }
                    } else {
                        resultMessage="El trazado ya no es válido. Revísalo en el mapa."
                    }
                }
                Button("Cancelar",role:.cancel) {}
            } message: {
                if let plan=routePlan {
                    Text("Se repartirán \(DurationFormat.full(plan.seconds)) en \(plan.cells.count) cuadrículas, proporcionalmente a \(Int(plan.distanceMeters.rounded())) metros de recorrido SUPUESTO. No es una ruta GPS registrada.")
                }
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
    private var routeEditor:some View {
        VStack(alignment:.leading,spacing:11) {
            Divider()
            HStack {
                Text("Recorrido estimado").font(.headline)
                Spacer()
                if routeMode {
                    Button("Ocultar") {
                        routeMode=false
                        addingWaypoints=false
                    }
                    .font(.caption)
                }
            }
            if !routeMode {
                Button {
                    routeMode=true
                } label: {
                    Label("Repartir por las cuadrículas atravesadas",
                          systemImage:"point.topleft.down.to.point.bottomright.curvepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
            } else {
                Text("La línea amarilla une las posiciones conocidas. Es una hipótesis: comprueba que coincide con el recorrido real. Puedes añadir puntos en el orden del trayecto.")
                    .font(.caption).foregroundStyle(.secondary)
                if gap.seconds>GPSGapRoutePlanner.cautionSeconds {
                    Label("Hueco largo: un reparto por distancia puede ser engañoso si estuviste parado. Confirma solo un recorrido que recuerdes.",
                          systemImage:"exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing:8) {
                    Button(addingWaypoints ? "Terminar dibujo" : "Añadir puntos en mapa") {
                        addingWaypoints.toggle()
                    }
                    .buttonStyle(.bordered)
                    .tint(addingWaypoints ? .yellow : .teal)
                    Button("Deshacer punto") {
                        if !waypoints.isEmpty { waypoints.removeLast() }
                    }
                    .disabled(waypoints.isEmpty)
                    .buttonStyle(.bordered)
                }
                if addingWaypoints {
                    Text("Toca el mapa para marcar un punto intermedio. Máximo 12. Termina el dibujo antes de ampliar el mapa.")
                        .font(.caption).foregroundStyle(.yellow)
                }
                Button("Volver al recorrido directo") {
                    waypoints.removeAll()
                    addingWaypoints=false
                }
                .font(.caption)
                .disabled(waypoints.isEmpty)
                if let plan=routePlan {
                    HStack {
                        Label("\(plan.cells.count) cuadrículas",systemImage:"square.grid.3x3")
                        Spacer()
                        Text(GPSGapMapLayout.distanceLabel(gap))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Text("Distancia del trazado: \(Int(plan.distanceMeters.rounded())) m · \(DurationFormat.full(gap.seconds))")
                        .font(.caption.monospacedDigit())
                    ForEach(plan.allocations.prefix(12)) { item in
                        HStack {
                            Text(model.label(for:item.cell))
                                .lineLimit(1)
                            Spacer(minLength:5)
                            Text("\(Int(item.meters.rounded())) m")
                                .foregroundStyle(.secondary)
                            Text(DurationFormat.full(item.seconds))
                                .foregroundStyle(.teal)
                        }.font(.caption)
                    }
                    if plan.allocations.count>12 {
                        Text("… y \(plan.allocations.count-12) tramos adicionales")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        addingWaypoints=false
                        showRouteConfirmation=true
                    } label: {
                        Label("Confirmar reparto del recorrido",
                              systemImage:"checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .accessibilityIdentifier("gpsGapConfirmEstimatedRoute")
                } else {
                    Label("El recorrido no se puede calcular: máximo dos horas y 20 km, o demasiadas casillas/puntos. Ajusta el trazado o utiliza la asignación manual.",
                          systemImage:"exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func choose(_ value:TimeGPSGapChoice) {
        selection=value
        showAssignConfirmation=true
    }
}
