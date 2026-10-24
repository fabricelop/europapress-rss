import SwiftUI
import MapKit

/// Full-history calendar, built from the canonical recorded GPS intervals.
/// Every continuous single-cell stay > 5 confirmed minutes can be inspected.
struct TimeSiteCalendarView: View {
    @ObservedObject var model: TimeModel
    @State private var selectedDay = Date()
    @State private var expandedCalendar = false
    @State private var allStays: [SiteGridStay] = []
    @State private var preparing = false
    @State private var generation = UUID()

    private var day: DateInterval {
        Calendar.current.dateInterval(of:.day,for:selectedDay) ??
        DateInterval(start:selectedDay,end:selectedDay.addingTimeInterval(86400))
    }
    private var visible: [SiteGridStay] {
        allStays.filter { $0.start < day.end && $0.end > day.start }
    }
    private var firstDate: Date? { allStays.last?.start }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    HStack {
                        Button {
                            selectedDay = Calendar.current.date(byAdding:.day,value:-1,to:selectedDay) ?? selectedDay
                        } label: { Label("Anterior",systemImage:"chevron.left") }
                        Spacer()
                        Button("Hoy") { selectedDay = Date() }
                        Spacer()
                        Button {
                            selectedDay = Calendar.current.date(byAdding:.day,value:1,to:selectedDay) ?? selectedDay
                        } label: { Label("Siguiente",systemImage:"chevron.right") }
                    }
                    .font(.caption)
                    if expandedCalendar {
                        DatePicker("Fecha",selection:$selectedDay,displayedComponents:.date)
                            .datePickerStyle(.graphical)
                    } else {
                        DatePicker("Fecha",selection:$selectedDay,displayedComponents:.date)
                            .datePickerStyle(.compact)
                    }
                    HStack {
                        Button(expandedCalendar ? "Ocultar calendario" : "Ver calendario") {
                            expandedCalendar.toggle()
                        }
                        Spacer()
                        if let firstDate {
                            Button("Ir al principio") { selectedDay = firstDate }
                        }
                    }
                    .font(.caption)
                }
            } header: {
                Text("Calendario de estancias")
            } footer: {
                Text("Se muestran todas las estancias continuas con más de cinco minutos GPS confirmados en una sola cuadrícula. No se incluye el tiempo sin mediciones.")
            }
            Section {
                if preparing {
                    ProgressView("Reconstruyendo histórico completo…")
                } else if visible.isEmpty {
                    ContentUnavailableView("Sin estancias este día",
                        systemImage:"calendar.badge.exclamationmark",
                        description:Text("Prueba otra fecha. El histórico incluye registros desde el inicio de Mi Mapa del Tiempo."))
                } else {
                    ForEach(visible) { stay in
                        NavigationLink {
                            TimeSiteStayEditor(model:model,stay:stay)
                        } label: {
                            stayRow(stay)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("\(visible.count) estancias")
                    Spacer()
                    Text(DateFormatter.localizedString(from:selectedDay,dateStyle:.medium,timeStyle:.none))
                }
            }
        }
        .navigationTitle("Histórico de sitios")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.topBarTrailing) {
                Button { rebuild() } label: { Image(systemName:"arrow.clockwise") }
                    .disabled(preparing)
            }
        }
        .onAppear { if allStays.isEmpty { rebuild() } }
        .onChange(of:model.data.intervals.count) { _,_ in rebuild() }
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
                                Text("Sitio").font(.caption2).foregroundStyle(.secondary)
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
            Section {
                Text("Las sugerencias para nuevas visitas se ordenan por el número de estancias en que hayas confirmado cada sitio. Las asignaciones automáticas no suman votos.")
                    .font(.caption).foregroundStyle(.secondary)
                let associated = model.siteOptions(for:stay.cell)
                ForEach(associated.indices,id:\.self) { index in
                    let row=associated[index]
                    HStack {
                        Label(row.site.name,systemImage:row.site.origin == "private" ? "house" : "mappin")
                        Spacer()
                        Text("\(row.confirmations)").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } header: { Text("Sitios asociados a esta cuadrícula") }
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
