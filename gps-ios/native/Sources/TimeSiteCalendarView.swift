import SwiftUI
import MapKit

/// Full-history calendar, built from the canonical recorded GPS intervals.
/// Every continuous single-cell stay > 5 confirmed minutes can be inspected.
struct TimeSiteCalendarView: View {
    @ObservedObject var model: TimeModel
    @State private var selectedDay = Date()
    @State private var expandedCalendar = false
    @State private var onlyUnclassified = false
    @State private var allStays: [SiteGridStay] = []
    @State private var preparing = false
    @State private var generation = UUID()

    private var day: DateInterval {
        SiteCalendarDay.interval(for: selectedDay)
    }
    private var visible: [SiteGridStay] {
        allStays.filter { $0.start < day.end && $0.end > day.start }
                .sorted { $0.start < $1.start }
    }
    private var report: SiteDayReport {
        SiteDayPresentation.build(visible.map {
            SiteDaySource(stay:$0,parts:model.siteParts(for:$0))
        },on:selectedDay)
    }
    private var firstDate: Date? { allStays.last?.start }
    private var displayedGroups: [SiteDayGroup] {
        guard onlyUnclassified else { return report.groups }
        return report.groups.filter { group in
            group.entries.contains { report.pendingStayIDs.contains($0.stay.id) }
        }
    }
    @State private var expandedGroups: Set<String> = []

    private func changeDay(_ delta: Int) {
        selectedDay = SiteCalendarDay.addingDays(delta, to: selectedDay)
        expandedGroups.removeAll()
    }

    /// Keeping every date control OUTSIDE List avoids the SwiftUI List-row
    /// automatic Button style, which can trigger multiple buttons at once
    /// (Anterior, Hoy, Siguiente and Mostrar calendario).
    private var daySelection: Binding<Date> {
        Binding(
            get: { selectedDay },
            set: { chosen in
                selectedDay = SiteCalendarDay.normalized(chosen)
                expandedGroups.removeAll()
            }
        )
    }

    private var calendarControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("CALENDARIO DE ESTANCIAS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            HStack(spacing: 8) {
                Button {
                    changeDay(-1)
                } label: {
                    Label("Anterior",systemImage:"chevron.left")
                        .frame(maxWidth:.infinity)
                }
                .accessibilityIdentifier("site-day-previous")
                Button("Hoy") {
                    selectedDay = SiteCalendarDay.normalized(.now)
                    expandedGroups.removeAll()
                }
                .accessibilityIdentifier("site-day-today")
                Button {
                    changeDay(1)
                } label: {
                    Label("Siguiente",systemImage:"chevron.right")
                        .frame(maxWidth:.infinity)
                }
                .accessibilityIdentifier("site-day-next")
            }
            .font(.subheadline)
            .buttonStyle(.bordered)

            HStack {
                Text(selectedDay,format:.dateTime.weekday(.wide).day().month(.wide).year())
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("site-day-selected-date")
                Spacer(minLength:4)
                DatePicker("Seleccionar fecha",selection:daySelection,
                           displayedComponents:.date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .fixedSize(horizontal:true,vertical:false)
                    .accessibilityIdentifier("site-day-picker")
            }

            if expandedCalendar {
                DatePicker("Calendario",selection:daySelection,
                           displayedComponents:.date)
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("site-day-graphical-calendar")
            }

            HStack {
                Button(expandedCalendar ? "Ocultar calendario" : "Ver calendario") {
                    expandedCalendar.toggle()
                }
                .accessibilityIdentifier("site-day-toggle-calendar")
                Spacer()
                if let firstDate {
                    Button("Ir al principio") {
                        selectedDay = SiteCalendarDay.normalized(firstDate)
                        expandedGroups.removeAll()
                    }
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(Color(.secondarySystemGroupedBackground))
    }

    var body: some View {
        VStack(spacing: 0) {
            calendarControls
            List {
                Section {
                    Text("Se muestran estancias continuas de más de cinco minutos GPS confirmados por cuadrícula. No se contabiliza el tiempo sin mediciones.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            if !preparing && !visible.isEmpty {
                Section("Resumen del día") {
                    VStack(alignment:.leading,spacing:7) {
                        HStack {
                            Text("\(Int((report.classifiedFraction*100).rounded())) % clasificado")
                                .font(.headline)
                            Spacer()
                            Text(report.isFullyClassified ? "Todo clasificado" : "Quedan sitios por asignar")
                                .font(.caption)
                                .foregroundStyle(report.isFullyClassified ? .teal : .secondary)
                        }
                        ProgressView(value:report.classifiedFraction)
                            .tint(.teal)
                        LabeledContent("Estancias sin identificar",
                                       value:"\(report.pendingStaysCount)")
                            .fontWeight(.semibold)
                        LabeledContent("Tiempo sin identificar",
                                       value:DurationFormat.full(report.unidentifiedGPS))
                        if report.pendingStaysCount > 0 {
                            Button(onlyUnclassified ? "Mostrar todas las estancias" :
                                   "Mostrar solo las pendientes (\(report.pendingStaysCount))") {
                                onlyUnclassified.toggle()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.teal)
                        } else if onlyUnclassified {
                            Button("Mostrar todas las estancias") { onlyUnclassified=false }
                                .buttonStyle(.borderless)
                        }
                        LabeledContent("Confirmado por ti",
                                       value:DurationFormat.full(report.confirmedGPS))
                        LabeledContent("Propuestas automáticas",
                                       value:"\(report.proposedStaysCount) estancias · \(DurationFormat.full(report.suggestedGPS))")
                        LabeledContent("De paso",
                                       value:DurationFormat.full(report.passingGPS))
                        LabeledContent("Tiempo GPS registrado",
                                       value:DurationFormat.full(report.totalGPS))
                        Text("Las propuestas cuentan como clasificadas sin que tengas que confirmarlas. Siguen siendo corregibles y no cuentan como confirmaciones manuales.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if !report.siteTotals.isEmpty {
                    Section("Tiempo por lugar") {
                        ForEach(report.siteTotals) { value in
                            if let site=model.siteNamed(value.id) {
                                VStack(alignment:.leading,spacing:3) {
                                    Text(site.name).font(.subheadline.weight(.medium))
                                    HStack {
                                        if value.confirmedSeconds > 0 {
                                            Text(DurationFormat.full(value.confirmedSeconds))
                                                .foregroundStyle(.teal)
                                        }
                                        if value.proposedSeconds > 0 {
                                            Text("Propuesto: \(DurationFormat.full(value.proposedSeconds))")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                if preparing {
                    ProgressView("Reconstruyendo histórico completo…")
                } else if visible.isEmpty {
                    ContentUnavailableView("Sin estancias este día",
                        systemImage:"calendar.badge.exclamationmark",
                        description:Text("Prueba otra fecha. El histórico incluye registros desde el inicio de Mi Mapa del Tiempo."))
                } else {
                    ForEach(displayedGroups) { group in
                        if group.isExpandable {
                            DisclosureGroup(isExpanded:Binding(
                                get:{ expandedGroups.contains(group.id) },
                                set:{ if $0 { expandedGroups.insert(group.id) }
                                       else { expandedGroups.remove(group.id) } }
                            )) {
                                ForEach(group.entries,id:\.stay.id) { item in
                                    NavigationLink {
                                        TimeSiteStayEditor(model:model,stay:item.stay)
                                    } label: {
                                        stayRow(item.stay)
                                    }
                                }
                            } label: {
                                groupRow(group)
                            }
                        } else if let item=group.entries.first {
                            NavigationLink {
                                TimeSiteStayEditor(model:model,stay:item.stay)
                            } label: {
                                stayRow(item.stay)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(onlyUnclassified ? "\(displayedGroups.count) entradas pendientes" :
                         "\(report.groups.count) entradas · \(visible.count) estancias")
                    Spacer()
                    Text(DateFormatter.localizedString(from:selectedDay,dateStyle:.medium,timeStyle:.none))
                }
            }
            }
        }
        .navigationTitle("Histórico de sitios")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.topBarLeading) {
                NavigationLink {
                    TimeMySitesView(model:model)
                } label: {
                    Label("Mis sitios",systemImage:"list.bullet")
                }
                .accessibilityLabel("Ver sitios y tiempos")
            }
            ToolbarItem(placement:.topBarTrailing) {
                Button { rebuild() } label: { Image(systemName:"arrow.clockwise") }
                    .disabled(preparing)
                    .accessibilityLabel("Actualizar histórico")
            }
        }
        .onAppear { if allStays.isEmpty { rebuild() } }
        .onChange(of:selectedDay) { _, chosen in
            let normalized=SiteCalendarDay.normalized(chosen)
            if selectedDay != normalized { selectedDay=normalized }
            expandedGroups.removeAll()
            onlyUnclassified=false
        }
        .onChange(of:model.data.intervals.count) { _,_ in rebuild() }
    }

    private func groupRow(_ group: SiteDayGroup) -> some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(spacing:6) {
                Text(group.firstStart,format:.dateTime.hour().minute())
                Text("–")
                Text(group.lastEnd,format:.dateTime.hour().minute())
                Spacer()
                Text(DurationFormat.full(group.recordedSeconds))
                    .foregroundStyle(.teal).fontWeight(.semibold)
            }
            .font(.caption.monospacedDigit())
            Text(group.siteID.flatMap { model.siteNamed($0)?.name } ?? "Lugar por revisar")
                .font(.subheadline.weight(.semibold))
            Text("\(group.entries.count) estancias · \(group.uniqueCells) cuadrículas · \(group.confirmed ? "Confirmadas" : "Propuestas")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical,4)
    }

    private func stayRow(_ stay: SiteGridStay) -> some View {
        let parts = model.siteParts(for:stay)
        let distinct = Array(Set(parts.compactMap { $0.kind == .place ? $0.siteID : nil }))
        let hasPassing = parts.contains { $0.kind == .passing }
        let title: String
        if distinct.count > 1 {
            title = "\(distinct.count) sitios en esta cuadrícula"
        } else if let id = distinct.first, let site = model.siteNamed(id) {
            title = site.name
        } else if hasPassing {
            title = "De paso"
        } else {
            title = "Lugar por identificar"
        }
        return VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(stay.start,format:.dateTime.hour().minute())
                    .monospacedDigit().font(.subheadline.bold())
                Text("–")
                Text(stay.end,format:.dateTime.hour().minute())
                    .monospacedDigit().font(.subheadline.bold())
                Spacer()
                Text(DurationFormat.full(stay.confirmedSeconds))
                    .font(.caption.weight(.semibold)).foregroundStyle(.teal)
            }
            Text(title).font(.subheadline)
            HStack(spacing:6) {
                Image(systemName:"square.dashed")
                Text(model.label(for:stay.cell))
                if model.data.siteStayParts.contains(where:{$0.stayID == stay.id}) {
                    Text("· Revisada")
                } else if !distinct.isEmpty {
                    Text("· Propuesta")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical,4)
    }

    private func rebuild() {
        let id = UUID()
        generation = id
        preparing = true
        let original = model.data.intervals
        DispatchQueue.global(qos:.userInitiated).async {
            let computed = SiteStayHistory.extract(original)
            DispatchQueue.main.async {
                guard generation == id else { return }
                allStays = computed
                preparing = false
            }
        }
    }
}

/// The user's manually chosen sub-periods are authoritative; automatic labels
/// are only suggestions and never split a stay or invent its timeline.
struct TimeSiteStayEditor: View {
    @ObservedObject var model: TimeModel
    let stay: SiteGridStay
    @State private var parts: [SiteStayPart]
    @State private var choosingPart: UUID?
    @State private var selectedAssociatedSite: IdentifiedSite?
    @State private var splittingPart: UUID?
    @State private var splitMoment: Date

    init(model:TimeModel,stay:SiteGridStay) {
        self.model = model
        self.stay = stay
        _parts = State(initialValue:model.siteParts(for:stay))
        _splitMoment = State(initialValue:stay.start.addingTimeInterval(stay.elapsed/2))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Cuadrícula",value:model.label(for:stay.cell))
                LabeledContent("Entrada",value:DateFormatter.localizedString(
                    from:stay.start,dateStyle:.medium,timeStyle:.short))
                LabeledContent("Salida",value:DateFormatter.localizedString(
                    from:stay.end,dateStyle:.medium,timeStyle:.short))
                LabeledContent("Tiempo GPS",value:DurationFormat.full(stay.confirmedSeconds))
                Text("Puedes identificar varios lugares durante una misma estancia. Las divisiones son manuales y nunca duplican tiempo.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Estancia continua") }

            Section("Sitios asociados a esta cuadrícula") {
                let associated = model.siteOptions(for:stay.cell)
                if associated.isEmpty {
                    Text("Todavía no has asociado ningún sitio. Usa «Elegir / cambiar» para buscarlo.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Toca un lugar para asignarlo directamente a esta estancia. Si la dividiste, podrás elegir el tramo.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(associated.indices,id:\.self) { index in
                        let row=associated[index]
                        Button {
                            assignAssociatedSite(row.site)
                        } label: {
                            HStack(spacing:10) {
                                Image(systemName: row.site.origin == "private" ? "house" : "mappin.circle")
                                    .foregroundStyle(.teal)
                                    .frame(width:20)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(row.site.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(row.confirmations > 0 ?
                                         "\(row.confirmations) confirmaciones aquí" :
                                         row.fromOtherSquares > 0 ?
                                         "Identificado en otra cuadrícula" :
                                         "Sitio guardado")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength:4)
                                Text("Usar")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.teal)
                                Image(systemName:"checkmark.circle")
                                    .foregroundStyle(.teal)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("site-associated-select-\(index)")
                    }
                }
            }

            Section("¿Dónde estaba?") {
                TimeSiteStayLocationMap(model:model,stay:stay)
            }

            Section("Lugares y tramos") {
                ForEach(parts.sorted { $0.from < $1.from }) { part in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text(part.from,format:.dateTime.hour().minute())
                            Text("–")
                            Text(part.to,format:.dateTime.hour().minute())
                            Spacer()
                            Text(DurationFormat.full(stay.confirmed(from:part.from,to:part.to)))
                                .fontWeight(.semibold)
                        }
                        .font(.caption.monospacedDigit())
                        HStack {
                            Image(systemName:part.kind == .passing ? "figure.walk" :
                                  part.kind == .place ? "mappin.circle.fill" : "questionmark.circle")
                            Text(label(for:part)).font(.subheadline.bold())
                            Spacer()
                            if part.kind == .place {
                                Text(part.confirmed ? "Confirmado" : "Propuesto")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(part.kind == .passing ? Color.orange : Color.primary)
                        HStack(spacing:14) {
                            Button("Elegir / cambiar") { choosingPart = part.id }
                            Button("De paso") { replace(part,kind:.passing,siteID:nil) }
                                .foregroundStyle(.orange)
                            Button("Dividir") {
                                splittingPart = part.id
                                splitMoment = part.from.addingTimeInterval(part.duration / 2)
                            }
                            .disabled(part.duration <= 90)
                        }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.plain)
                        if let index = parts.sorted(by:{$0.from < $1.from})
                            .firstIndex(where:{$0.id == part.id}), index > 0 {
                            Button("Unir con el tramo anterior") {
                                if let joined=SiteStayHistory.mergeWithPrevious(
                                    parts,partID:part.id,stay:stay) {
                                    save(joined)
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        if splittingPart == part.id {
                            DatePicker("Hora del corte",selection:$splitMoment,
                                       in:part.from.addingTimeInterval(31)...part.to.addingTimeInterval(-31),
                                       displayedComponents:[.date,.hourAndMinute])
                                .font(.caption)
                            HStack {
                                Button("Confirmar división") {
                                    if let divided=SiteStayHistory.split(parts,partID:part.id,
                                                                          at:splitMoment,stay:stay) {
                                        save(divided)
                                    }
                                    splittingPart = nil
                                }
                                Spacer()
                                Button("Cancelar") { splittingPart = nil }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical,7)
                }
            }

        }
        .confirmationDialog("Seleccionar tramo de la estancia",
            isPresented: Binding(get: { selectedAssociatedSite != nil },
                                 set: { if !$0 { selectedAssociatedSite = nil } }),
            titleVisibility: .visible) {
            if let site=selectedAssociatedSite {
                ForEach(parts.sorted { $0.from < $1.from }) { part in
                    Button("\(part.from.formatted(date:.omitted,time:.shortened)) – \(part.to.formatted(date:.omitted,time:.shortened))") {
                        replace(part,kind:.place,siteID:site.id)
                        selectedAssociatedSite=nil
                    }
                }
            }
            Button("Cancelar",role:.cancel) { selectedAssociatedSite=nil }
        } message: {
            Text("Esta estancia está dividida. Elige qué tramo corresponde al sitio.")
        }
        .navigationTitle("Detalle de estancia")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item:Binding<SitePartSelection?>(
            get: { choosingPart.map { SitePartSelection(id:$0) } },
            set: { choosingPart=$0?.id }
        )) { selection in
            NavigationStack {
                TimeSitePickerView(model:model,cell:stay.cell) { picked in
                    guard let part=parts.first(where:{$0.id == selection.id}) else { return }
                    replace(part,kind:.place,siteID:picked.id)
                }
            }
        }
        .onAppear { parts=model.siteParts(for:stay) }
    }

    private func assignAssociatedSite(_ site:IdentifiedSite) {
        let ordered=parts.sorted { $0.from < $1.from }
        if ordered.count == 1, let part=ordered.first {
            replace(part,kind:.place,siteID:site.id)
        } else {
            selectedAssociatedSite=site
        }
    }

    private func label(for part:SiteStayPart) -> String {
        switch part.kind {
        case .passing: return "De paso"
        case .unassigned: return "Sin identificar"
        case .place: return part.siteID.flatMap { model.siteNamed($0)?.name } ?? "Sitio desconocido"
        }
    }

    private func replace(_ part:SiteStayPart,kind:SiteStayPartKind,siteID:UUID?) {
        var copy=parts
        guard let i=copy.firstIndex(where:{$0.id == part.id}) else { return }
        copy[i].kind=kind
        copy[i].siteID=siteID
        copy[i].confirmed = kind == .place && siteID != nil
        save(copy)
    }

    private func save(_ updated:[SiteStayPart]) {
        guard SiteStayHistory.valid(updated,for:stay) else { return }
        parts=updated.sorted { $0.from < $1.from }
        model.writeSiteParts(parts,stay:stay)
    }
}

private struct SitePartSelection:Identifiable {
    let id:UUID
}


/// Read-only map for one historical stay. Green border is the 100m grid
/// square. Blue dots are real, retained GPS fixes; if none exists, the
/// square is displayed alone rather than inventing an exact position.
private struct TimeSiteStayLocationMap: View {
    @ObservedObject var model: TimeModel
    let stay: SiteGridStay

    @State private var camera: MapCameraPosition
    @State private var retainedSamples: [GPSPoint] = []

    init(model: TimeModel, stay: SiteGridStay) {
        self.model = model
        self.stay = stay
        _camera = State(initialValue: .region(Self.mapRegion(for: stay.cell)))
    }

    private static func mapRegion(for cell: Cell) -> MKCoordinateRegion {
        MKCoordinateRegion(center: Grid.center(cell),
                           span: MKCoordinateSpan(latitudeDelta: 0.003,
                                                  longitudeDelta: 0.004))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(position: $camera) {
                MapPolygon(coordinates: Grid.polygon(stay.cell))
                    .foregroundStyle(Color.teal.opacity(0.24))
                    .stroke(Color.teal, lineWidth: 2.5)

                ForEach(retainedSamples) { fix in
                    Annotation("", coordinate: CLLocationCoordinate2D(
                        latitude: fix.latitude, longitude: fix.longitude)) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 235)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                Button {
                    camera = .region(Self.mapRegion(for: stay.cell))
                } label: {
                    Image(systemName: "scope")
                        .foregroundStyle(.teal)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Centrar en la cuadrícula")
                .padding(9)
            }
            if retainedSamples.isEmpty {
                Text("Contorno verde: cuadrícula registrada. No hay posiciones GPS individuales conservadas durante esta estancia; no se puede precisar el establecimiento solo con el mapa.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(.teal).frame(width: 8, height: 8)
                    Text("Cuadrícula")
                    Spacer(minLength: 6)
                    Circle().fill(.blue).frame(width: 8, height: 8)
                    Text("GPS registrado (\(retainedSamples.count))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text("Puedes ampliar y mover el mapa. Los puntos son mediciones GPS, no una identificación segura del local.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onAppear { loadFixes() }
    }

    private func loadFixes() {
        let center = Grid.center(stay.cell)
        let reference = CLLocation(latitude: center.latitude,
                                   longitude: center.longitude)
        let candidates = model.data.fixes.filter { fix in
            guard fix.date >= stay.start, fix.date <= stay.end,
                  fix.accuracy >= 0, fix.accuracy <= 80 else { return false }
            return reference.distance(from: CLLocation(
                latitude: fix.latitude, longitude: fix.longitude)) <= 220
        }
        // Historical stays may contain hundreds of retained fixes. The map
        // renders at most 24 measured samples evenly across the visit.
        guard candidates.count > 24 else {
            retainedSamples = candidates
            return
        }
        let count = 24
        retainedSamples = (0..<count).map { index in
            let position = index * (candidates.count - 1) / (count - 1)
            return candidates[position]
        }
    }
}
