import SwiftUI

/// Search result details. The date/time lines are derived from actual GPS
/// grid stays and explicitly selected or locally proposed venue identities.
struct TimeSiteVisitHistoryView: View {
    @ObservedObject var model:TimeModel
    let site:IdentifiedSite
    let visits:[SiteVisitRecord]

    private var orderedDays:[Date] {
        Array(Set(visits.map { Calendar.current.startOfDay(for:$0.from) }))
            .sorted(by:>)
    }

    private func onDay(_ day:Date) -> [SiteVisitRecord] {
        visits.filter { Calendar.current.isDate($0.from,inSameDayAs:day) }
              .sorted { $0.from < $1.from }
    }

    private var uniqueStays:Int {
        Set(visits.map { $0.stay.id }).count
    }

    var body:some View {
        List {
            Section("Resumen del sitio") {
                Label(site.name,systemImage:site.origin == "private" ?
                      "house.fill" : "mappin.circle.fill")
                    .font(.headline)
                LabeledContent("Días con estancias",value:"\(orderedDays.count)")
                LabeledContent("Estancias distintas",value:"\(uniqueStays)")
                LabeledContent("Tiempo registrado",
                     value:DurationFormat.full(visits.reduce(0){$0+$1.gpsSeconds}))
                let human=visits.filter(\.confirmed)
                let proposed=visits.filter{ !$0.confirmed }
                LabeledContent("Períodos confirmados",value:"\(human.count)")
                if !proposed.isEmpty {
                    LabeledContent("Períodos propuestos",value:"\(proposed.count)")
                }
                Text("Puedes abrir cualquier período para consultar su mapa o corregir el sitio asignado. El tiempo mostrado procede de los intervalos GPS registrados.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if visits.isEmpty {
                Section {
                    ContentUnavailableView("Sin estancias asociadas",
                        systemImage:"calendar.badge.exclamationmark",
                        description:Text("Todavía no existen visitas confirmadas o propuestas para este sitio."))
                }
            } else {
                ForEach(orderedDays,id:\.self) { day in
                    Section {
                        ForEach(onDay(day)) { entry in
                            NavigationLink {
                                TimeSiteStayEditor(model:model,stay:entry.stay)
                            } label: {
                                VStack(alignment:.leading,spacing:6) {
                                    HStack(spacing:4) {
                                        Text(entry.from,format:.dateTime.hour().minute())
                                        Text("–")
                                        Text(entry.to,format:.dateTime.hour().minute())
                                        Spacer()
                                        Text(DurationFormat.full(entry.gpsSeconds))
                                            .foregroundStyle(.teal)
                                            .fontWeight(.semibold)
                                    }
                                    .font(.subheadline.monospacedDigit())
                                    HStack(spacing:6) {
                                        Image(systemName:entry.confirmed ?
                                              "checkmark.circle.fill":"questionmark.circle")
                                        Text(entry.confirmed ? "Confirmado" : "Propuesto")
                                        Text("·")
                                        Text(model.label(for:entry.cell))
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.vertical,5)
                            }
                        }
                    } header: {
                        Text(day,format:.dateTime.weekday(.wide).day().month(.wide).year())
                    } footer: {
                        Text("\(onDay(day).count) períodos · \(DurationFormat.full(onDay(day).reduce(0){$0+$1.gpsSeconds}))")
                    }
                }
            }
        }
        .navigationTitle("Historial del sitio")
        .navigationBarTitleDisplayMode(.inline)
    }
}
