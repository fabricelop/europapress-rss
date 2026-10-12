import SwiftUI

struct CellHistoryView: View {
    @ObservedObject var model: TimeModel
    let cell: Cell
    @Environment(\.dismiss) private var dismiss
    @State private var nameEditor = false
    @State private var goToMapAfterDismiss = false

    private var visits:[TimeVisit] {
        TimeVisitIndex.visits(model.data.intervals,cells:[cell.id])
    }
    var body: some View {
        List {
            Section("Cuadrícula") {
                LabeledContent("Nombre",value:model.label(for:cell))
                LabeledContent("Tiempo confirmado",
                    value:DurationFormat.full(visits.reduce(0) { $0+$1.confirmedSeconds }))
                LabeledContent("Visitas",value:String(visits.count))
                LabeledContent("Días con presencia",
                    value:String(TimeVisitIndex.daily(visits).count))
                LabeledContent("Media por visita",
                    value:DurationFormat.full(visits.isEmpty ? 0 :
                        visits.reduce(0) { $0+$1.confirmedSeconds }/Double(visits.count)))
                LabeledContent("Identificador",value:cell.id)
                if let zone=model.primaryZone(for:cell) {
                    LabeledContent("Zona",value:zone.name)
                    LabeledContent("Cuadrículas de la zona",value:String(zone.cellIDs.count))
                }
                Button("Cambiar nombre") { nameEditor=true }
                Button {
                    goToMapAfterDismiss=true
                    dismiss()
                } label: {
                    Label("Ver en el mapa",systemImage:"map")
                }
            }
            Section("Territorios") {
                if let territory=model.data.territoryCache[cell.id] {
                    ForEach(TerritoryLevel.allCases) { level in
                        if let name=level.value(territory) {
                            LabeledContent(level.title,value:name)
                        }
                    }
                } else {
                    Text("Territorio pendiente de identificar.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Histórico") {
                TimeVisitCalendar(model:model,cellIDs:[cell.id])
            }
            Section {
                Text("Los intervalos internos se consolidan en visitas. Los segundos registrados permanecen intactos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.label(for:cell))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented:$nameEditor) {
            TimeNameEditor(model:model,cell:cell)
        }
        .onDisappear {
            if goToMapAfterDismiss {
                model.navigate(to:cell)
            }
        }
    }
}

struct UserPlacesView: View {
    @ObservedObject var model: TimeModel
    private var window:DateInterval? { TimeAnalytics.window(for:model.period,now:.now) }
    private var sorted:[UserPlace] {
        model.data.places.sorted { a,b in
            TimeAttribution.totals(model.data.intervals,cellIDs:a.normalizedCellIDs,window:window) >
            TimeAttribution.totals(model.data.intervals,cellIDs:b.normalizedCellIDs,window:window)
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if sorted.isEmpty {
                ContentUnavailableView("Aún no hay zonas",systemImage:"mappin.and.ellipse",
                    description:Text("Pon nombre a una cuadrícula. Repite el mismo nombre en otra próxima para unirlas automáticamente."))
            }
            ForEach(sorted) { place in
                NavigationLink {
                    UserPlaceDetailView(model:model,placeID:place.id)
                } label: {
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text(place.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(place.cellIDs.count) cuadrícula(s)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(DurationFormat.full(TimeAttribution.totals(model.data.intervals,
                            cellIDs:place.normalizedCellIDs,window:window)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                        Image(systemName:"chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(11)
                    .background(Color(.secondarySystemGroupedBackground),
                                in:RoundedRectangle(cornerRadius:13))
                }
            }
            Text("Las zonas pueden agrupar cuadrículas nombradas o dibujadas.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct UserPlaceDetailView: View {
    @ObservedObject var model: TimeModel
    let placeID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var changingName=false
    @State private var newName=""
    @State private var failedName=false
    @State private var editingCell:Cell?
    private var place:UserPlace? { model.data.places.first(where:{$0.id==placeID}) }
    private var visits:[TimeVisit] {
        TimeVisitIndex.visits(model.data.intervals,cells:place?.normalizedCellIDs ?? [])
    }

    var body: some View {
        List {
            if let place {
                Section("Zona") {
                    LabeledContent("Nombre",value:place.name)
                    LabeledContent("Tiempo confirmado",
                        value:DurationFormat.full(visits.reduce(0) {$0+$1.confirmedSeconds}))
                    LabeledContent("Visitas",value:String(visits.count))
                    LabeledContent("Días con presencia",
                        value:String(TimeVisitIndex.daily(visits).count))
                    LabeledContent("Media por visita",
                        value:DurationFormat.full(visits.isEmpty ? 0 :
                            visits.reduce(0) { $0+$1.confirmedSeconds }/Double(visits.count)))
                    LabeledContent("Cuadrículas",value:String(place.cellIDs.count))
                    Button("Renombrar toda la zona") {
                        newName=place.name
                        changingName=true
                    }
                    if model.renameUndoAvailable {
                        Button("Deshacer último renombrado") {
                            _ = model.undoLastRename()
                        }.foregroundStyle(.orange)
                    }
                }
                Section("Calendario de presencia") {
                    TimeVisitCalendar(model:model,cellIDs:place.normalizedCellIDs)
                }
                Section("Cuadrículas de esta zona") {
                    ForEach(place.cellIDs,id:\.self) { id in
                        if let cell=TimeAnalytics.cell(id) {
                            Button {
                                editingCell=cell
                            } label: {
                                HStack {
                                    Text("Zona \(model.data.shortIDs[id] ?? 0)")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("Cambiar nombre")
                                        .font(.caption).foregroundStyle(.teal)
                                }
                            }
                        }
                    }
                    Text("Para sacar una cuadrícula de la zona, cámbiale o quítale el nombre. No se modifica su historial.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Quitar nombre a todas las cuadrículas",role:.destructive) {
                        model.removePlace(place)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(place?.name ?? "Zona")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Nuevo nombre de la zona",isPresented:$changingName) {
            TextField("Nombre",text:$newName)
            Button("Guardar") {
                if !model.renameWholePlace(placeID,to:newName) { failedName=true }
            }
            Button("Cancelar",role:.cancel) {}
        } message: {
            Text("Cambia el nombre de todas las cuadrículas de esta zona, conservando sus tiempos.")
        }
        .alert("Nombre ya utilizado",isPresented:$failedName) {
            Button("Entendido") {}
        } message: {
            Text("Ya existe otra zona con ese nombre. Renombra sus cuadrículas individualmente para decidir si unirlas.")
        }
        .sheet(item:$editingCell) { c in
            TimeNameEditor(model:model,cell:c)
        }
    }
}
