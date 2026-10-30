import SwiftUI

/// One expandable panel inside the map square. Shared SiteVisitLookup
/// decisions mean there are no second guesses from adjacent GPS squares.
struct CellSiteHistorySection:View {
    @ObservedObject var model:TimeModel
    let cell:Cell
    @State private var ranked:[CellSiteRecord]=[]
    @State private var preparing=false
    @State private var loaded=false
    @State private var generation=UUID()
    @State private var expandedSites:Set<UUID>=[]
    @State private var expandedYears:Set<String>=[]
    @State private var expandedMonths:Set<String>=[]
    @State private var expandedDays:Set<String>=[]

    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            if preparing && !loaded {
                ProgressView("Buscando sitios de esta cuadrícula…")
            } else if ranked.isEmpty {
                Text("No hay todavía sitios asignados a estancias GPS de esta cuadrícula.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(ranked.count) sitios · ordenados por tiempo GPS registrado")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ranked) { site in
                    siteGroup(site)
                }
            }
            if preparing && loaded {
                ProgressView("Actualizando sitios…")
                    .font(.caption2)
            }
        }
        .onAppear { if !loaded { rebuild() } }
        .onChange(of:model.data.siteStayParts) { _,_ in rebuild() }
        .onChange(of:model.data.siteStayAssignments) { _,_ in rebuild() }
        .onChange(of:model.data.identifiedSites) { _,_ in rebuild() }
        // A return to the sheet should not recalculate the full history
        // unless an attribution decision has actually changed.
    }

    private func siteGroup(_ item:CellSiteRecord)->some View {
        DisclosureGroup(isExpanded:Binding(
            get:{expandedSites.contains(item.id)},
            set:{ if $0 { expandedSites.insert(item.id) }
                  else { expandedSites.remove(item.id) } }
        )) {
            ForEach(item.years) { year in
                yearGroup(year,siteID:item.id)
            }
        } label: {
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:6) {
                    Image(systemName:item.site.origin == "private" ?
                          "house.fill":"mappin.circle.fill")
                        .foregroundStyle(.teal)
                    Text(item.site.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength:4)
                    Text(DurationFormat.full(item.seconds))
                        .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                }
                Text("\(item.years.count) años · \(item.days.count) días · confirmados: \(DurationFormat.small(item.verifiedSeconds))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
    }

    /// Keep the same progressive navigation as Histórico:
    /// site → year → month → day → individual recorded periods.
    private func yearGroup(_ year:CellSiteYear,siteID:UUID)->some View {
        let key=siteID.uuidString + "|" + String(year.number)
        return DisclosureGroup(isExpanded:Binding(
            get:{expandedYears.contains(key)},
            set:{ if $0 { expandedYears.insert(key) }
                  else { expandedYears.remove(key) } }
        )) {
            ForEach(year.months) { month in
                monthGroup(month,siteID:siteID)
            }
        } label: {
            HStack(spacing:6) {
                Text(String(year.number)).font(.subheadline.weight(.semibold))
                Spacer(minLength:5)
                Text(DurationFormat.full(year.seconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(.teal)
            }
        }
    }

    private func monthGroup(_ month:CellSiteMonth,siteID:UUID)->some View {
        let key=siteID.uuidString + "|" + month.id
        return DisclosureGroup(isExpanded:Binding(
            get:{expandedMonths.contains(key)},
            set:{ if $0 { expandedMonths.insert(key) }
                  else { expandedMonths.remove(key) } }
        )) {
            ForEach(month.days) { day in
                dayGroup(day,siteID:siteID)
            }
        } label: {
            HStack(spacing:6) {
                Text(month.title)
                    .font(.subheadline)
                Spacer(minLength:5)
                Text("\(month.days.count) días")
                    .font(.caption).foregroundStyle(.secondary)
                Text(DurationFormat.small(month.seconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(.teal)
            }
        }
    }

    private func dayGroup(_ day:CellSiteDay,siteID:UUID)->some View {
        let key=siteID.uuidString + "|" + String(day.date.timeIntervalSince1970)
        return DisclosureGroup(isExpanded:Binding(
            get:{expandedDays.contains(key)},
            set:{ if $0 {expandedDays.insert(key)}
                  else {expandedDays.remove(key)} }
        )) {
            ForEach(day.portions) { part in
                NavigationLink {
                    TimeSiteStayEditor(model:model,stay:part.visit.stay)
                } label: {
                    VStack(alignment:.leading,spacing:4) {
                        HStack {
                            Text(part.from,format:.dateTime.hour().minute())
                            Text("–")
                            Text(part.to,format:.dateTime.hour().minute())
                            Spacer(minLength:3)
                            Text(DurationFormat.full(part.seconds))
                                .foregroundStyle(.teal)
                        }
                        .font(.caption.monospacedDigit())
                        Label(part.visit.confirmed ? "Confirmado":"Propuesto",
                              systemImage:part.visit.confirmed ?
                              "checkmark.circle.fill":"questionmark.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical,4)
                }
            }
        } label: {
            HStack {
                Text(day.date.formatted(
                    .dateTime.day().weekday(.wide)
                        .locale(Locale(identifier:"es_ES"))))
                    .font(.caption.weight(.medium))
                Spacer()
                Text(DurationFormat.full(day.seconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rebuild() {
        let request=UUID()
        generation=request
        preparing=true
        let intervals=model.data.intervals
        let parts=model.data.siteStayParts
        let assignments=model.data.siteStayAssignments
        let sites=model.data.identifiedSites
        let selected=cell
        DispatchQueue.global(qos:.utility).async {
            let result=CellSiteHistoryIndex.ranked(
                cell:selected,intervals:intervals,parts:parts,
                assignments:assignments,sites:sites)
            DispatchQueue.main.async {
                guard generation == request else { return }
                ranked=result
                loaded=true
                preparing=false
            }
        }
    }
}
