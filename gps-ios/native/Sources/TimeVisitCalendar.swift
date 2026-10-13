import SwiftUI

/// Calendario compacto de episodios. Los segundos y las muestras originales
/// siguen íntegros en el historial y no se reconstruye tiempo sin GPS.
struct TimeVisitCalendar: View {
    @ObservedObject var model: TimeModel
    let cellIDs: Set<String>
    @State private var month: Date = Calendar.current.dateInterval(of:.month,for:.now)?.start ?? .now
    @State private var selectedDay: Date?

    private var zoneTimeZone:TimeZone? {
        cellIDs.compactMap { model.data.territoryCache[$0]?.timeZoneIdentifier }
            .compactMap(TimeZone.init(identifier:)).first
    }
    private var calendar:Calendar {
        var c=Calendar.current
        c.firstWeekday=2
        if let zoneTimeZone { c.timeZone=zoneTimeZone }
        return c
    }
    private var allVisits:[TimeVisit] {
        TimeVisitIndex.visits(model.data.intervals,cells:cellIDs,
            fixes:model.data.fixes,powerEvents:model.data.powerEvents,
            manualBreaks:model.data.manualBreaks)
    }
    private var visibleVisits:[TimeVisit] {
        TimeVisitIndex.visible(allVisits)
    }
    private var days:[Date:(seconds:TimeInterval,visits:Int)] {
        // El total incluye incluso fracciones de segundo que se ocultan
        // como fila independiente. El recuento incluye solo visitas visibles.
        let totals=TimeVisitIndex.daily(allVisits,calendar:calendar)
        let shown=Dictionary(uniqueKeysWithValues:
            TimeVisitIndex.daily(visibleVisits,calendar:calendar)
                .map { ($0.date,$0.visits) })
        return Dictionary(uniqueKeysWithValues:totals.compactMap { entry in
            let count=shown[entry.date] ?? 0
            return count>0 ? (entry.date,(entry.seconds,count)) : nil
        })
    }
    private var monthDays:[Date?] {
        guard let range=calendar.range(of:.day,in:.month,for:month),
              let first=calendar.dateInterval(of:.month,for:month)?.start else { return [] }
        let prefix=(calendar.component(.weekday,from:first)-calendar.firstWeekday+7)%7
        return Array(repeating:nil,count:prefix)+range.compactMap { day in
            calendar.date(byAdding:.day,value:day-1,to:first)
        }.map(Optional.some)
    }
    private var focus:Date {
        selectedDay ?? days.keys.filter {
            calendar.isDate($0,equalTo:month,toGranularity:.month)
        }.max() ?? month
    }
    private var focusVisits:[(visit:TimeVisit,start:Date,end:Date,seconds:TimeInterval)] {
        TimeVisitIndex.portions(visibleVisits,day:calendar.startOfDay(for:focus),
                                calendar:calendar)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Calendario de visitas").font(.headline)
                if let zoneTimeZone {
                    Text("Horas locales: \(zoneTimeZone.identifier)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength:0)
                Text("\(visibleVisits.count) visitas")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing:10) {
                Button { shift(-12) } label: { Image(systemName:"chevron.left.2") }
                    .accessibilityLabel("Año anterior")
                Button { shift(-1) } label: { Image(systemName:"chevron.left") }
                    .accessibilityLabel("Mes anterior")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()
                    .locale(Locale(identifier:"es_ES"))))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { shift(1) } label: { Image(systemName:"chevron.right") }
                    .accessibilityLabel("Mes siguiente")
                Button { shift(12) } label: { Image(systemName:"chevron.right.2") }
                    .accessibilityLabel("Año siguiente")
            }.buttonStyle(.borderless)
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:5),count:7),
                      spacing:6) {
                ForEach(["L","M","X","J","V","S","D"],id:\.self) { day in
                    Text(day).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(monthDays.enumerated()),id:\.offset) { _,date in
                    if let date {
                        let day=calendar.startOfDay(for:date)
                        let visited=days[day] != nil
                        let focused=calendar.isDate(day,inSameDayAs:focus)
                        Button { selectedDay=day } label: {
                            Text("\(calendar.component(.day,from:date))")
                                .font(.caption.weight(visited ? .bold : .regular))
                                .frame(maxWidth:.infinity,minHeight:35)
                                .foregroundStyle(focused ? Color.white :
                                    (visited ? Color.teal : Color.secondary))
                                .background(focused ? Color.teal :
                                    (visited ? Color.teal.opacity(0.13) : .clear),
                                    in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height:35)
                    }
                }
            }
            Divider()
            VStack(alignment:.leading,spacing:7) {
                Text(focus.formatted(.dateTime.weekday(.wide).day().month(.wide).year()
                    .locale(Locale(identifier:"es_ES"))))
                    .font(.subheadline.weight(.semibold))
                if let day=days[calendar.startOfDay(for:focus)] {
                    Text("\(DurationFormat.full(day.seconds)) · \(day.visits) visita(s)")
                        .font(.caption).foregroundStyle(.teal)
                } else {
                    Text("Sin visitas de al menos 1 segundo ese día")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(focusVisits,id:\.visit.id) { item in
                    TimeCalendarVisitRow(visit:item.visit,start:item.start,
                        end:item.end,seconds:item.seconds,
                        timeZone:calendar.timeZone)
                }
            }
        }
        .onAppear {
            if let last=TimeVisitIndex.daily(visibleVisits,calendar:calendar).first {
                month=calendar.dateInterval(of:.month,for:last.date)?.start ?? month
                selectedDay=last.date
            }
        }
    }
    private func shift(_ months:Int) {
        if let next=calendar.date(byAdding:.month,value:months,to:month) {
            month=next
            selectedDay=nil
        }
    }
}

private struct TimeCalendarVisitRow:View {
    let visit:TimeVisit
    let start:Date
    let end:Date
    let seconds:TimeInterval
    let timeZone:TimeZone
    @State private var isExpanded=false

    private func localTime(_ date:Date)->String {
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"es_ES")
        formatter.timeZone=timeZone
        formatter.timeStyle = .short
        return formatter.string(from:date)
    }
    private var unconfirmedSeconds:TimeInterval {
        max(0,end.timeIntervalSince(start)-seconds)
    }
    private var details:[TimeVisitIndex.DetailPeriod] {
        TimeVisitIndex.detailPeriods(visit,from:start,to:end)
    }
    var body:some View {
        DisclosureGroup(isExpanded:$isExpanded) {
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Text("Tiempo registrado")
                    Spacer(minLength:6)
                    Text(DurationFormat.full(seconds))
                        .foregroundStyle(.teal)
                }
                if visit.mergedSessions>1 {
                    Label("\(visit.mergedSessions) tramos reunidos",
                          systemImage:"square.stack.3d.up")
                }
                // Solo advertir por un hueco realmente significativo, no
                // por segundos perdidos entre lecturas consecutivas.
                if unconfirmedSeconds>=60 {
                    Label("\(DurationFormat.full(unconfirmedSeconds)) sin GPS; no sumados",
                          systemImage:"clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                if details.count>1 {
                    Divider()
                    Text("Tramos registrados").fontWeight(.medium)
                    ForEach(Array(details.prefix(12))) { part in
                        HStack {
                            Text("\(localTime(part.start)) – \(localTime(part.end))")
                            Spacer(minLength:5)
                            Text(DurationFormat.full(part.seconds))
                                .foregroundStyle(.teal)
                        }
                    }
                    if details.count>12 {
                        Text("\(details.count-12) tramos adicionales")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.top,5)
        } label: {
            HStack(alignment:.firstTextBaseline,spacing:8) {
                Text("\(localTime(start)) – \(localTime(end))")
                    .font(.subheadline)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if unconfirmedSeconds>=60 {
                    Image(systemName:"clock.badge.exclamationmark")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength:4)
                Text(DurationFormat.full(seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.teal)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .tint(.teal)
        .padding(.vertical,3)
    }
}
