import SwiftUI

/// Consulta visitas consolidadas; no muestra cada intervalo de 1–6 segundos.
struct TimeVisitCalendar: View {
    @ObservedObject var model: TimeModel
    let cellIDs: Set<String>
    @State private var month: Date = Calendar.current.dateInterval(of:.month,for:.now)?.start ?? .now
    @State private var selectedDay: Date?
    private var calendar:Calendar {
        var c=Calendar.current
        c.firstWeekday=2 // lunes
        return c
    }
    private var allVisits:[TimeVisit] {
        TimeVisitIndex.visits(model.data.intervals,cells:cellIDs)
    }
    private var days:[Date:(seconds:TimeInterval,visits:Int)] {
        Dictionary(uniqueKeysWithValues:TimeVisitIndex.daily(allVisits,calendar:calendar)
            .map { ($0.date,($0.seconds,$0.visits)) })
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
        selectedDay ?? days.keys.filter { calendar.isDate($0,equalTo:month,toGranularity:.month) }
            .max() ?? month
    }
    private var focusVisits:[(visit:TimeVisit,start:Date,end:Date,seconds:TimeInterval)] {
        TimeVisitIndex.portions(allVisits,day:calendar.startOfDay(for:focus),calendar:calendar)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:13) {
            HStack {
                Text("Calendario de visitas").font(.headline)
                Spacer()
                Text("\(allVisits.count) visitas").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing:10) {
                Button { shift(-12) } label: { Image(systemName:"chevron.left.2") }
                    .accessibilityLabel("Año anterior")
                Button { shift(-1) } label: { Image(systemName:"chevron.left") }
                    .accessibilityLabel("Mes anterior")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier:"es_ES"))))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { shift(1) } label: { Image(systemName:"chevron.right") }
                    .accessibilityLabel("Mes siguiente")
                Button { shift(12) } label: { Image(systemName:"chevron.right.2") }
                    .accessibilityLabel("Año siguiente")
            }.buttonStyle(.borderless)
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:5),count:7),spacing:6) {
                ForEach(["L","M","X","J","V","S","D"],id:\.self) { day in
                    Text(day).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(monthDays.enumerated()),id:\.offset) { _,date in
                    if let date {
                        let day=calendar.startOfDay(for:date)
                        let visited=days[day] != nil
                        let focused=calendar.isDate(day,inSameDayAs:focus)
                        Button {
                            selectedDay=day
                        } label: {
                            Text("\(calendar.component(.day,from:date))")
                                .font(.caption.weight(visited ? .bold : .regular))
                                .frame(maxWidth:.infinity,minHeight:35)
                                .foregroundStyle(focused ? Color.white : (visited ? Color.teal : Color.secondary))
                                .background(focused ? Color.teal : (visited ? Color.teal.opacity(0.13) : .clear),
                                            in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height:35)
                    }
                }
            }
            Divider()
            VStack(alignment:.leading,spacing:8) {
                Text(focus.formatted(.dateTime.weekday(.wide).day().month(.wide).year()
                    .locale(Locale(identifier:"es_ES"))))
                    .font(.subheadline.weight(.semibold))
                if let day=days[calendar.startOfDay(for:focus)] {
                    Text("\(DurationFormat.full(day.seconds)) · \(day.visits) visita(s)")
                        .font(.caption).foregroundStyle(.teal)
                } else {
                    Text("Sin tiempo registrado en este lugar ese día")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(focusVisits,id:\.visit.id) { item in
                    HStack {
                        VStack(alignment:.leading,spacing:3) {
                            Text("\(item.start.formatted(date:.omitted,time:.shortened)) – \(item.end.formatted(date:.omitted,time:.shortened))")
                                .font(.subheadline)
                            if item.visit.duration-item.visit.confirmedSeconds>1 {
                                Text("Incluye un hueco GPS breve no atribuido")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(DurationFormat.full(item.seconds))
                            .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                    }
                    .padding(.vertical,4)
                }
            }
        }
        .onAppear {
            if let last=TimeVisitIndex.daily(allVisits,calendar:calendar).first {
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
