import SwiftUI

/// Calendario compacto de episodios. Los segundos y las muestras originales
/// siguen íntegros en el historial y no se reconstruye tiempo sin GPS.
struct TimeVisitCalendar: View {
    @ObservedObject var model: TimeModel
    let cellIDs: Set<String>
    @State private var month: Date = Calendar.current.dateInterval(of:.month,for:.now)?.start ?? .now
    @State private var selectedDay: Date?
    @State private var selectedGPSGap:TimeGPSGapCandidate?
    @State private var showGapConfirmation=false
    @State private var gapOutcome:TimeGPSGapConfirmationOutcome?

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
        let shown:[Date:Int]=Dictionary(uniqueKeysWithValues:
            TimeVisitIndex.daily(visibleVisits,calendar:calendar)
                .map { ($0.date,$0.visits) })
        var result:[Date:(seconds:TimeInterval,visits:Int)]=[:]
        for entry in totals {
            let count:Int=shown[entry.date] ?? 0
            if count>0 { result[entry.date]=(seconds:entry.seconds,visits:count) }
        }
        return result
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
    private var reviewableGaps:[TimeGPSGapCandidate] {
        TimeGPSGapRecovery.candidates(
            intervals:model.data.intervals,fixes:model.data.fixes,
            manualBreaks:model.data.manualBreaks,
            events:model.data.powerEvents,cells:cellIDs)
        .filter { gap in
            calendar.isDate(gap.start,inSameDayAs:focus) &&
            calendar.isDate(gap.end,inSameDayAs:gap.start)
        }
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
                TimeDayTimeline(model:model,day:focus,calendar:calendar)
                ForEach(focusVisits,id:\.visit.id) { item in
                    TimeCalendarVisitRow(model:model,visit:item.visit,
                        start:item.start,end:item.end,seconds:item.seconds,
                        timeZone:calendar.timeZone)
                }
                if let gapOutcome {
                    Label(gapOutcome.message,
                          systemImage:gapOutcome.isSuccess ?
                            "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(gapOutcome.isSuccess ? Color.teal : Color.orange)
                        .fixedSize(horizontal:false,vertical:true)
                        .padding(10)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .background(gapOutcome.isSuccess ? Color.teal.opacity(0.10) :
                                    Color.orange.opacity(0.10),
                                    in:RoundedRectangle(cornerRadius:10))
                        .accessibilityIdentifier("gpsGapSaveOutcome")
                }
                ForEach(reviewableGaps) { gap in
                    VStack(alignment:.leading,spacing:5) {
                        HStack(spacing:6) {
                            Image(systemName:"location.slash.circle")
                                .foregroundStyle(.orange)
                            Text("GPS sin datos: \(localGapTime(gap.start)) – \(localGapTime(gap.end))")
                                .font(.caption.weight(.semibold))
                        }
                        Text("\(DurationFormat.full(gap.seconds)) sin atribuir. Puedes recuperarlo solo si permaneciste aquí todo ese tiempo.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Confirmar que permanecí aquí") {
                            gapOutcome=nil
                            selectedGPSGap=gap
                            showGapConfirmation=true
                        }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .tint(.teal)
                    }
                    .padding(9)
                    .background(Color.orange.opacity(0.07),
                                in:RoundedRectangle(cornerRadius:10))
                }
            }
        }
        .alert("¿Permaneciste en la cuadrícula?",isPresented:$showGapConfirmation,
               presenting:selectedGPSGap) { gap in
            Button("Añadir como estimado") {
                // No ocultar silenciosamente un error de base de datos o un
                // intervalo que cambió durante la confirmación.
                let result=model.confirmUnobservedStay(gap)
                withAnimation(.easeInOut(duration:0.2)) {
                    gapOutcome=result
                }
                selectedGPSGap=nil
            }
            Button("Cancelar",role:.cancel) { selectedGPSGap=nil }
        } message: { gap in
            Text("Entre \(localGapTime(gap.start)) y \(localGapTime(gap.end)) no hubo GPS suficiente. Si confirmas que no saliste de esta cuadrícula, se añadirán \(DurationFormat.full(gap.seconds)) como tiempo ASUMIDO, no observado. El historial GPS original se conservará.")
        }
        .onAppear {
            if let last=TimeVisitIndex.daily(visibleVisits,calendar:calendar).first {
                month=calendar.dateInterval(of:.month,for:last.date)?.start ?? month
                selectedDay=last.date
            }
        }
    }
    private func localGapTime(_ value:Date)->String {
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"es_ES")
        formatter.timeZone=calendar.timeZone
        formatter.timeStyle = .short
        return formatter.string(from:value)
    }
    private func shift(_ months:Int) {
        if let next=calendar.date(byAdding:.month,value:months,to:month) {
            month=next
            selectedDay=nil
        }
    }
}

struct TimeCalendarVisitRow:View {
    @ObservedObject var model:TimeModel
    let visit:TimeVisit
    let start:Date
    let end:Date
    let seconds:TimeInterval
    let timeZone:TimeZone
    var onEdited: (() -> Void)? = nil
    @State private var isExpanded=false
    @State private var breakDate:Date=Date()
    @State private var showSplitEditor=false

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
                // Solo advertir por un hueco realmente significativo, no
                // por segundos perdidos entre lecturas consecutivas.
                if unconfirmedSeconds>=60 {
                    Label("\(DurationFormat.full(unconfirmedSeconds)) sin GPS; no sumados",
                          systemImage:"clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                if end.timeIntervalSince(start)>120 {
                    Button("Ajustar esta visita") {
                        breakDate=start.addingTimeInterval(end.timeIntervalSince(start)/2)
                        showSplitEditor=true
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
                if details.count>1 {
                    Text("\(details.count) tramos reunidos")
                    ForEach(Array(details.prefix(3))) { part in
                        HStack {
                            Text("\(localTime(part.start)) – \(localTime(part.end))")
                            Spacer(minLength:5)
                            Text(DurationFormat.small(part.seconds))
                                .foregroundStyle(.teal)
                        }
                    }
                    if details.count>3 {
                        Text("Y \(details.count-3) tramos más")
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
        .sheet(isPresented:$showSplitEditor) {
            NavigationStack {
                Form {
                    Section {
                        DatePicker("Separar a las",selection:$breakDate,
                            in:start...end,displayedComponents:[.hourAndMinute])
                    } footer: {
                        Text("Solo se cambia cómo aparecen las visitas; no se altera el tiempo registrado.")
                    }
                    if model.data.manualBreaks.contains(where:{
                        abs($0.timeIntervalSince(start))<1
                    }) {
                        Section {
                            Button("Quitar separación anterior") {
                                model.removeSplit(at:start)
                                showSplitEditor=false
                                onEdited?()
                            }
                        }
                    }
                }
                .navigationTitle("Ajustar visita")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {
                        Button("Cancelar") { showSplitEditor=false }
                    }
                    ToolbarItem(placement:.confirmationAction) {
                        Button("Guardar") {
                            if breakDate>start && breakDate<end {
                                model.splitEpisode(at:breakDate)
                                onEdited?()
                            }
                            showSplitEditor=false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}
