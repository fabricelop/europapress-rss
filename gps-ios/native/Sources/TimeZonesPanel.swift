import SwiftUI
import MapKit

struct TimeZonesPanel: View {
    @ObservedObject var model: TimeModel
    @State private var creating = false
    private var values: [String:TimeInterval] {
        TimeAttribution.byCell(model.data.intervals,
            window:TimeAnalytics.window(for:model.period,now:.now))
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("Mis zonas").font(.headline)
                    Text("Zonas construidas con cuadrículas completas. Su tiempo no se duplica en el total global.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { creating = true } label: {
                    Label("Dibujar",systemImage:"pencil.tip.crop.circle")
                }.buttonStyle(.borderedProminent)
            }
            if model.data.customZones.isEmpty {
                ContentUnavailableView("Aún no has dibujado zonas",
                    systemImage:"square.3.layers.3d",
                    description:Text("Dibuja un contorno en el mapa para seleccionar cuadrículas, incluidas las que visitarás en el futuro."))
            }
            ForEach(model.data.customZones) { zone in
                NavigationLink {
                    TimeZoneEditor(model:model,existing:zone)
                } label: {
                    HStack {
                        VStack(alignment:.leading,spacing:3) {
                            Text(zone.name).font(.subheadline.bold())
                            Text("\(zone.cellIDs.count) cuadrículas · \(String(format:"%.2f",Double(zone.cellIDs.count)*0.01)) km²")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(DurationFormat.full(zone.cells.reduce(0) {
                            $0 + (values[$1] ?? 0)
                        })).font(.subheadline.monospacedDigit()).foregroundStyle(.teal)
                    }.padding(10)
                }
            }
        }
        .sheet(isPresented:$creating) {
            NavigationStack { TimeZoneEditor(model:model,existing:nil) }
        }
    }
}

struct TimeZoneEditor: View {
    @ObservedObject var model: TimeModel
    let existing: TimeCustomZone?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var drawing = false
    @State private var adjusting = false
    @State private var points: [CGPoint] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var warning = ""
    @State private var confirmDelete = false

    private var candidateCells: [Cell] {
        Array(selected.prefix(TimeZoneGeometry.maximumCells)).compactMap(TimeAnalytics.cell)
    }
    var body: some View {
        VStack(spacing:10) {
            HStack(spacing:10) {
                TextField("Nombre de la zona",text:$name)
                    .textFieldStyle(.roundedBorder)
                Text("\(selected.count) celdas").font(.caption.monospacedDigit())
            }.padding(.horizontal)
            HStack(spacing:8) {
                Button(drawing ? "Dibujando…" : "Dibujar contorno") {
                    drawing = true; adjusting = false; points = []; warning = ""
                }.buttonStyle(.borderedProminent).disabled(drawing)
                Button(adjusting ? "Editando celdas" : "Añadir/quitar celdas") {
                    adjusting.toggle(); drawing = false
                }.buttonStyle(.bordered)
                Button("Mover mapa") {
                    drawing = false; adjusting = false; points = []
                }.buttonStyle(.bordered)
            }.font(.caption)
            MapReader { proxy in
                Map(position:$camera) {
                    ForEach(candidateCells) { cell in
                        MapPolygon(coordinates:Grid.polygon(cell))
                            .foregroundStyle(Color.teal.opacity(0.46))
                            .stroke(.teal,lineWidth:1)
                    }
                }
                .mapStyle(.standard)
                .overlay {
                    if drawing || adjusting {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                guard adjusting,let c=proxy.convert(location,from:.local) else { return }
                                let cell=Grid.cell(latitude:c.latitude,longitude:c.longitude)
                                if selected.contains(cell.id) { selected.remove(cell.id) }
                                else if selected.count < TimeZoneGeometry.maximumCells {
                                    selected.insert(cell.id)
                                }
                            }
                            .gesture(DragGesture(minimumDistance:12)
                                .onChanged { value in
                                    guard drawing else { return }
                                    points.append(value.location)
                                }
                                .onEnded { _ in
                                    guard drawing else { return }
                                    let polygon=points.compactMap { proxy.convert($0,from:.local) }
                                    let cells=TimeZoneGeometry.selectedCells(inside:polygon)
                                    if cells.isEmpty {
                                        warning="Contorno demasiado pequeño o grande. Acerca el mapa y encierra varias cuadrículas."
                                    } else if selected.union(cells).count > TimeZoneGeometry.maximumCells {
                                        warning="Máximo 3.000 cuadrículas por zona."
                                    } else {
                                        selected.formUnion(cells)
                                        warning=""
                                    }
                                    points=[]
                                    drawing=false
                                })
                            .overlay {
                                if drawing && points.count > 1 {
                                    Canvas { context,_ in
                                        var path=Path()
                                        path.addLines(points)
                                        context.stroke(path,with:.color(.orange),lineWidth:4)
                                    }.allowsHitTesting(false)
                                }
                            }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius:16))
            .padding(.horizontal)
            Text(warning.isEmpty ?
                 (drawing ? "Desliza el dedo para encerrar las cuadrículas." :
                  adjusting ? "Toca una cuadrícula para añadirla o quitarla." :
                  "Mueve y amplía el mapa. Después elige Dibujar contorno.") : warning)
                .font(.caption).foregroundStyle(warning.isEmpty ? Color.secondary : .orange)
                .padding(.horizontal)
            HStack {
                Button("Cancelar"){dismiss()}.buttonStyle(.bordered)
                Spacer()
                if existing != nil {
                    Button("Eliminar",role:.destructive){ confirmDelete=true }
                        .buttonStyle(.bordered)
                }
                Button("Guardar zona") {
                    model.putZone(TimeCustomZone(id:existing?.id ?? UUID(),
                        name:name.trimmingCharacters(in:.whitespacesAndNewlines),
                        cellIDs:selected.sorted(),createdAt:existing?.createdAt ?? .now))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || selected.isEmpty)
            }.padding()
        }
        .navigationTitle(existing == nil ? "Nueva zona" : "Editar zona")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name=existing?.name ?? ""
            selected=existing?.cells ?? []
            camera = .region(existing.flatMap {
                $0.cellIDs.first.flatMap(TimeAnalytics.cell).map { cell in
                    MKCoordinateRegion(center:Grid.center(cell),
                       span:MKCoordinateSpan(latitudeDelta:0.014,longitudeDelta:0.014))
                }
            } ?? model.data.camera.region)
        }
        .confirmationDialog("¿Eliminar esta zona?",isPresented:$confirmDelete) {
            Button("Eliminar zona",role:.destructive) {
                if let existing { model.deleteZone(existing.id) }
                dismiss()
            }
        } message: { Text("Las cuadrículas y los tiempos originales no se borrarán.") }
    }
}
