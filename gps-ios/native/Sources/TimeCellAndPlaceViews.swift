import SwiftUI

struct CellHistoryView: View {
    @ObservedObject var model: TimeModel
    let cell: Cell
    @State private var editing = false
    @State private var name = ""
    private var daily: [(date:Date,seconds:TimeInterval,visits:Int)] {
        TimeAttribution.byDay(model.data.intervals,cellIDs:[cell.id])
    }
    var body: some View {
        List {
            Section("Cuadrícula") {
                LabeledContent("Nombre",value:model.label(for:cell))
                LabeledContent("Tiempo histórico",
                    value:DurationFormat.full(TimeAttribution.totals(model.data.intervals,cellIDs:[cell.id])))
                LabeledContent("Días con tiempo",value:String(daily.count))
                LabeledContent("Identificador",value:cell.id)
                Button("Cambiar nombre") {
                    name = model.data.names[cell.id] ?? ""
                    editing = true
                }
                Button {
                    model.navigate(to:cell)
                } label: {
                    Label("Ver en el mapa",systemImage:"map")
                }
            }
            Section("Cuándo estuviste aquí") {
                if daily.isEmpty { Text("Todavía sin intervalos registrados") }
                ForEach(daily,id:\.date) { day in
                    DisclosureGroup {
                        let entries=TimeAttribution.canonical(model.data.intervals).filter {
                            $0.cell.id == cell.id &&
                            $0.start < (Calendar.current.date(byAdding:.day,value:1,to:day.date) ?? day.date) &&
                            $0.end > day.date
                        }
                        ForEach(entries) { interval in
                            VStack(alignment:.leading,spacing:2) {
                                let begin=max(day.date,interval.start)
                                let finish=min(Calendar.current.date(byAdding:.day,value:1,to:day.date) ?? interval.end,interval.end)
                                Text("\(begin.formatted(date:.omitted,time:.shortened)) – \(finish.formatted(date:.omitted,time:.shortened))")
                                    .font(.subheadline)
                                Text(DurationFormat.full(finish.timeIntervalSince(begin)) + " · " + interval.quality)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        VStack(alignment:.leading,spacing:3) {
                            Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()
                                .locale(Locale(identifier:"es_ES"))))
                                .font(.subheadline.weight(.medium))
                            Text(DurationFormat.full(day.seconds))
                                .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                        }
                    }
                }
            }
        }
        .navigationTitle(model.label(for:cell))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Nombre de la cuadrícula",isPresented:$editing) {
            TextField("Nombre (vacío = Zona corta)",text:$name)
            Button("Guardar") { model.rename(cell,to:name) }
            Button("Cancelar",role:.cancel) {}
        }
    }
}

struct UserPlacesView: View {
    @ObservedObject var model: TimeModel
    private var window: DateInterval? { TimeAnalytics.window(for:model.period,now:.now) }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if model.data.places.isEmpty {
                ContentUnavailableView("Aún no has creado lugares",systemImage:"square.3.layers.3d",
                   description:Text("En el mapa, toca «Agrupar», selecciona las cuadrículas y pon nombre al lugar."))
            }
            ForEach(model.data.places) { place in
                NavigationLink {
                    UserPlaceDetailView(model:model,placeID:place.id)
                } label: {
                    HStack {
                        VStack(alignment:.leading,spacing:5) {
                            Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(place.cellIDs.count) cuadrículas").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(DurationFormat.full(TimeAttribution.totals(model.data.intervals,
                              cellIDs:place.normalizedCellIDs,window:window)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                        Image(systemName:"chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(12).background(Color(.secondarySystemGroupedBackground),
                                             in:RoundedRectangle(cornerRadius:12))
                }
            }
        }
    }
}

struct UserPlaceDetailView: View {
    @ObservedObject var model: TimeModel
    let placeID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var title = ""
    @State private var cellIDs = Set<String>()
    private var place:UserPlace? { model.data.places.first(where:{$0.id == placeID}) }
    private var daily:[(date:Date,seconds:TimeInterval,visits:Int)] {
        TimeAttribution.byDay(model.data.intervals,cellIDs:place?.normalizedCellIDs ?? [])
    }
    var body: some View {
        List {
            if let place {
                Section("Lugar") {
                    LabeledContent("Total",
                       value:DurationFormat.full(TimeAttribution.totals(model.data.intervals,
                                            cellIDs:place.normalizedCellIDs)))
                    LabeledContent("Cuadrículas",value:String(place.cellIDs.count))
                    Button("Editar nombre y cuadrículas") {
                        title=place.name
                        cellIDs=place.normalizedCellIDs
                        editing=true
                    }
                    Button("Eliminar lugar (conservar histórico)",role:.destructive) {
                        model.removePlace(place)
                        dismiss()
                    }
                }
                Section("Histórico por días") {
                    ForEach(daily,id:\.date) { day in
                        LabeledContent(day.date.formatted(.dateTime.day().month().year()),
                                       value:DurationFormat.full(day.seconds))
                    }
                }
            }
        }
        .navigationTitle(place?.name ?? "Lugar")
        .sheet(isPresented:$editing) {
            NavigationStack {
                List {
                    Section("Nombre") {
                        TextField("Nombre del lugar",text:$title)
                    }
                    Section("Cuadrículas incluidas") {
                        ForEach(model.allCells.sorted(by:{$0.id < $1.id})) { c in
                            let occupied = model.data.places.contains {
                                $0.id != placeID && $0.cellIDs.contains(c.id)
                            }
                            Toggle(model.label(for:c),
                                isOn:Binding(get:{cellIDs.contains(c.id)},
                                  set:{ enabled in
                                      if enabled { cellIDs.insert(c.id) }
                                      else { cellIDs.remove(c.id) }
                                  }))
                                .disabled(occupied)
                        }
                    }
                    Text("Una cuadrícula solo puede pertenecer a un lugar. Los intervalos GPS originales no se modifican.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .navigationTitle("Editar lugar")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {
                        Button("Cancelar") { editing=false }
                    }
                    ToolbarItem(placement:.confirmationAction) {
                        Button("Guardar") {
                            if let place, !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                                !cellIDs.isEmpty {
                                model.changePlace(place,name:title)
                                model.changePlaceCells(place,cells:cellIDs)
                            }
                            editing=false
                        }.disabled(cellIDs.isEmpty || title.trimmingCharacters(in:.whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}
