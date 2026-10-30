import SwiftUI

/// The screen keeps an immutable snapshot while it is open. New GPS points
/// must not rebuild a potentially years-long visit tree on every model tick.
struct CellHistoryView: View {
    let model: TimeModel
    let cell: Cell
    @Environment(\.dismiss) private var dismiss
    @State private var nameEditor = false
    @State private var goToMapAfterDismiss = false
    @State private var title = ""
    @State private var snapshot: CellPresenceSnapshot?
    @State private var rebuilding = false
    @State private var generation = UUID()
    @State private var showGrid = false
    @State private var showTerritories = false
    @State private var showSites = false
    @State private var showHistory = false

    var body: some View {
        List {
            DisclosureGroup("Cuadrícula", isExpanded: $showGrid) {
                LabeledContent("Nombre", value: title)
                if let snapshot {
                    LabeledContent("Tiempo confirmado",
                        value: DurationFormat.full(snapshot.confirmedSeconds))
                    LabeledContent("Visitas", value: String(snapshot.visitCount))
                    LabeledContent("Días con presencia", value: String(snapshot.dayCount))
                    LabeledContent("Media por visita",
                        value: DurationFormat.full(snapshot.averageSeconds))
                } else {
                    ProgressView("Calculando resumen…")
                }
                if let zone = model.primaryZone(for: cell) {
                    LabeledContent("Zona", value: zone.name)
                    LabeledContent("Cuadrículas de la zona",
                                   value: String(zone.cellIDs.count))
                }
                Button("Cambiar nombre") { nameEditor = true }
                Button {
                    goToMapAfterDismiss = true
                    dismiss()
                } label: {
                    Label("Ver en el mapa", systemImage: "map")
                }
            }

            DisclosureGroup("Sitios", isExpanded: $showSites) {
                CellSiteHistorySection(model:model,cell:cell)
            }

            DisclosureGroup("Territorios", isExpanded: $showTerritories) {
                if let territory = model.data.territoryCache[cell.id] {
                    ForEach(TerritoryLevel.allCases) { level in
                        if let name = level.value(territory) {
                            LabeledContent(level.title, value: name)
                        }
                    }
                } else {
                    Text("Territorio pendiente de identificar.")
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Histórico", isExpanded: $showHistory) {
                if let snapshot {
                    TimeCellPresenceTree(model: model, snapshot: snapshot,
                                         onEdited: rebuild)
                } else if rebuilding {
                    ProgressView("Preparando los días con presencia…")
                } else {
                    Text("Sin visitas registradas.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title.isEmpty ? model.label(for: cell) : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { rebuild() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(rebuilding)
                .accessibilityLabel("Actualizar histórico de cuadrícula")
            }
        }
        .sheet(isPresented: $nameEditor, onDismiss: {
            title = model.label(for: cell)
        }) {
            TimeNameEditor(model: model, cell: cell)
        }
        .onAppear {
            title = model.label(for: cell)
            if snapshot == nil { rebuild() }
        }
        .onDisappear {
            if goToMapAfterDismiss {
                model.navigate(to: cell)
            }
        }
    }

    private func rebuild() {
        let request = UUID()
        generation = request
        rebuilding = true
        // Capture the data on the UI thread. Read no mutable TimeModel state in
        // the worker queue; a live GPS update may arrive during construction.
        let intervals = model.data.intervals
        let fixes = model.data.fixes
        let events = model.data.powerEvents
        let breaks = model.data.manualBreaks
        let id = cell.id
        var calendar = Calendar.current
        if let identifier = model.data.territoryCache[id]?.timeZoneIdentifier,
           let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let visits = TimeVisitIndex.visits(
                intervals, cells: [id], fixes: fixes,
                powerEvents: events, manualBreaks: breaks)
            let total = TimeAttribution.totals(intervals, cellIDs: [id])
            let calculated = CellPresenceIndex.build(visits, total: total,
                                                      calendar: calendar)
            DispatchQueue.main.async {
                guard generation == request else { return }
                snapshot = calculated
                rebuilding = false
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
        TimeVisitIndex.visible(TimeVisitIndex.visits(model.data.intervals,cells:place?.normalizedCellIDs ?? [],
            fixes:model.data.fixes,powerEvents:model.data.powerEvents,
            manualBreaks:model.data.manualBreaks))
    }

    var body: some View {
        List {
            if let place {
                Section("Zona") {
                    LabeledContent("Nombre",value:place.name)
                    LabeledContent("Tiempo confirmado",
                        value:DurationFormat.full(TimeAttribution.totals(model.data.intervals,
                            cellIDs:place.normalizedCellIDs)))
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
