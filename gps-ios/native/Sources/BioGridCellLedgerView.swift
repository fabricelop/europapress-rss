import SwiftUI
import Charts

/// Una sola ficha por cuadrícula. La tabla utiliza registros históricos
/// deterministas del simulador; el único dato proyectado es el GPS vivo de hoy.
struct BioGridCellLedgerView: View {
    @ObservedObject var model: TimeModel
    @ObservedObject var engine: BioGridController
    let cell: Cell
    let colors: [Color]
    @State private var selectedDate: Date
    @State private var expandedFamily: Int? = nil
    @State private var showChart = false
    @Environment(\.dismiss) private var dismiss

    init(model: TimeModel, engine: BioGridController, cell: Cell,
         colors: [Color], initialDate: Date) {
        self.model = model
        self.engine = engine
        self.cell = cell
        self.colors = colors
        _selectedDate = State(initialValue:
            BioGridController.madrid.startOfDay(for:initialDate))
    }

    private var calendar: Calendar { BioGridController.madrid }
    private var today: Date { calendar.startOfDay(for:.now) }
    private var first: Date {
        min(engine.snapshot?.historical.first?.date ?? today, today)
    }
    private var day: Date { calendar.startOfDay(for:selectedDate) }
    private var isToday: Bool { calendar.isDate(day,inSameDayAs:today) }

    private var snapshot: BioGridSnapshot? { engine.snapshot }
    private var activity: BioGridCellDay {
        snapshot?.cellDays[cell.id]?.first(where: {
            calendar.isDate($0.date,inSameDayAs:day)
        }) ?? BioGridCellDay(date:day)
    }
    private var before: [Int64] {
        snapshot?.cellHistory[cell.id]?
            .last(where: { $0.date < day })?.counts ??
            Array(repeating:0,count:7)
    }

    private func settledCounts() -> [Int64] {
        snapshot?.cellHistory[cell.id]?
            .last(where: { $0.date <= day })?.counts ??
            Array(repeating:0,count:7)
    }

    private func liveBirths(at now: Date) -> Int64 {
        guard isToday, let snapshot,
              model.activeCell == cell,
              model.isResting ||
                (model.recording &&
                 (model.gpsFixAge(now:now) ?? 10000) <= 180) else { return 0 }
        return BioGridBirthTicker.project(
            remainder:snapshot.remainingSeconds[cell.id] ?? 0,
            sourceEnd:snapshot.lastIntervalEnds[cell.id],
            visitStart:model.currentVisitStart ?? model.data.gpsRest?.startedAt,
            latestFix:model.lastGPSFix,
            now:now,
            resting:model.isResting).provisionalBirths
    }

    private func todayFamily(at now: Date) -> Int {
        let weekday = Calendar.current.component(.weekday,from:now)
        return (weekday+5)%7
    }

    private func population(at now: Date) -> [Int64] {
        var counts = settledCounts()
        let provisional = liveBirths(at:now)
        if provisional > 0 {
            counts[todayFamily(at:now)] += provisional
        }
        return counts
    }

    private func births(_ family: Int, at now: Date) -> Int64 {
        activity.births[family] +
            (family == todayFamily(at:now) ? liveBirths(at:now) : 0)
    }

    private func amount(_ number: Int64, sign: Bool = false) -> String {
        if number == 0 { return "—" }
        return sign && number > 0 ? "+\(number.formatted())" : number.formatted()
    }

    private func step(_ offset: Int) {
        guard let newDay = calendar.date(byAdding:.day,value:offset,to:day),
              newDay >= first, newDay <= today else { return }
        selectedDate = newDay
        expandedFamily = nil
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from:.now,by:1)) { timeline in
                let now = timeline.date
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        heading(at:now)
                        dateSelector
                        summary(at:now)
                        table(at:now)
                        if let family = expandedFamily {
                            directionalDetail(family)
                        }
                        Button {
                            showChart = true
                        } label: {
                            Label("Ver evolución de esta cuadrícula",
                                  systemImage:"chart.xyaxis.line")
                                .frame(maxWidth:.infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        Text("Los saldos cuadran por familia: población anterior + nacimientos + llegadas − salidas − bajas = población final. Las direcciones son relativas a esta cuadrícula.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal:false,vertical:true)
                    }
                    .padding(13)
                }
            }
            .navigationTitle("Detalle de cuadrícula")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .sheet(isPresented:$showChart) {
                BioGridCellChartView(cell:cell,
                    history:snapshot?.cellHistory[cell.id] ?? [],
                    colors:colors) { date in
                        selectedDate = calendar.startOfDay(for:date)
                        expandedFamily = nil
                        showChart = false
                    }
            }
        }
    }

    private func heading(at now:Date) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(model.label(for:cell))
                .font(.title3.bold())
            let coordinate = Grid.center(cell)
            Text(String(format:"%.5f°, %.5f° · cuadrícula de 100 m",
                        coordinate.latitude,coordinate.longitude))
                .font(.caption).foregroundStyle(.secondary)
            if isToday, liveBirths(at:now)>0 {
                Label("Los nacimientos provisionales se distinguen hasta que los confirma el GPS.",
                      systemImage:"clock")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var dateSelector:some View {
        HStack(spacing:10) {
            Button { step(-1) } label: {
                Image(systemName:"chevron.left")
                    .frame(width:28,height:32)
            }
            .disabled(day <= first)
            Spacer(minLength:0)
            DatePicker("Fecha",selection:$selectedDate,
                       in:first...today,displayedComponents:.date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .environment(\.timeZone,calendar.timeZone)
                .onChange(of:selectedDate) { _,_ in expandedFamily = nil }
            if isToday {
                Text("HOY")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            }
            Spacer(minLength:0)
            Button { step(1) } label: {
                Image(systemName:"chevron.right")
                    .frame(width:28,height:32)
            }
            .disabled(day >= today)
        }
        .buttonStyle(.bordered)
    }

    private func summary(at now:Date) -> some View {
        let counts = population(at:now)
        let total = counts.reduce(0,+)
        let maxCount = counts.max() ?? 0
        let dominant = counts.firstIndex(of:maxCount) ?? 0
        let born = (0..<7).reduce(Int64(0)) { $0 + births($1,at:now) }
        return VStack(alignment:.leading,spacing:7) {
            HStack {
                Text(isToday ? "Población actual" : "Población al terminar el día")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(total.formatted())
                    .font(.title2.bold().monospacedDigit())
            }
            HStack(spacing:7) {
                Text(BioGridEngine.letters[dominant])
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .frame(width:25,height:25)
                    .background(colors[dominant],
                                in:RoundedRectangle(cornerRadius:5))
                Text("Familia dominante · \(maxCount.formatted())")
                    .font(.subheadline)
                Spacer()
                Text("+\(born.formatted()) nacidas")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Text(isToday ? "El total incluye nacimientos confirmados y, cuando corresponde, provisionales en esta cuadrícula." :
                 "Estado tras el ciclo de medianoche y los nacimientos del día seleccionado.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(11)
        .background(Color.blue.opacity(0.07),
                    in:RoundedRectangle(cornerRadius:11))
    }

    private func table(at now:Date) -> some View {
        let counts = population(at:now)
        return VStack(alignment:.leading,spacing:8) {
            Text("Las siete familias").font(.headline)
            Text("Toca una familia para desplegar llegadas y salidas por N/S/E/O.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal,showsIndicators:true) {
                VStack(spacing:0) {
                    columnsRow(["Fam.","Total","Nacen","Llegan","Salen","Bajas","Δ"],
                               header:true)
                    Divider()
                    ForEach(0..<7,id:\.self) { family in
                        Button {
                            expandedFamily = expandedFamily == family ? nil : family
                        } label: {
                            familyRow(family,counts:counts,now:now)
                        }
                        .buttonStyle(.plain)
                        if family < 6 { Divider() }
                    }
                    Divider()
                    let totalBirths = (0..<7).reduce(Int64(0)) {
                        $0 + births($1,at:now)
                    }
                    let totalArrivals = (0..<7).reduce(Int64(0)) {
                        $0 + activity.arrived($1)
                    }
                    let totalDepartures = (0..<7).reduce(Int64(0)) {
                        $0 + activity.departed($1)
                    }
                    let totalDeaths = activity.deaths.reduce(0,+)
                    let totalDelta = counts.reduce(0,+) - before.reduce(0,+)
                    columnsRow(["Σ",
                        counts.reduce(0,+).formatted(),
                        amount(totalBirths,sign:true),
                        amount(totalArrivals,sign:true),
                        amount(totalDepartures),
                        amount(totalDeaths),
                        amount(totalDelta,sign:true)],
                        header:false,bold:true)
                }
                .padding(.vertical,6)
            }
            .padding(7)
            .background(Color(.secondarySystemGroupedBackground),
                        in:RoundedRectangle(cornerRadius:10))
            Text("Llegan, Salen y Bajas: madrugada que inicia el día seleccionado. Nacen: a lo largo del día. Δ: variación desde el cierre anterior.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func columnsRow(_ entries:[String], header:Bool,
                            bold:Bool=false) -> some View {
        HStack(spacing:4) {
            ForEach(Array(entries.enumerated()),id:\.offset) { index,text in
                Text(text)
                    .font(header ? .caption2.weight(.semibold) :
                          bold ? .caption.weight(.semibold) : .caption)
                    .monospacedDigit()
                    .foregroundStyle(header ? Color.secondary : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width:index==0 ? 45 : 53,
                           height:header ? 27 : 35,
                           alignment:index==0 ? .leading : .trailing)
            }
        }
    }

    private func familyRow(_ family:Int,counts:[Int64],now:Date)->some View {
        let net = births(family,at:now) + activity.arrived(family)
            - activity.departed(family) - activity.deaths[family]
        let entries:[String] = [
            BioGridEngine.letters[family],
            counts[family].formatted(),
            amount(births(family,at:now),sign:true),
            amount(activity.arrived(family),sign:true),
            amount(activity.departed(family)),
            amount(activity.deaths[family]),
            amount(net,sign:true)
        ]
        return HStack(spacing:4) {
            ForEach(0..<entries.count,id:\.self) { index in
                HStack(spacing:2) {
                    if index == 0 {
                        Circle().fill(colors[family])
                            .frame(width:8,height:8)
                    }
                    Text(entries[index])
                        .font(.caption.monospacedDigit())
                        .fontWeight(index==1 ? .bold : .regular)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(width:index==0 ? 45 : 53,height:37,
                       alignment:index==0 ? .leading : .trailing)
            }
        }
        .background(expandedFamily == family ? colors[family].opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
    }

    private func directionalDetail(_ family:Int) -> some View {
        let names = ["Norte","Sur","Este","Oeste"]
        return VStack(alignment:.leading,spacing:9) {
            HStack {
                Text("Familia \(BioGridEngine.letters[family]) · movimientos nocturnos")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    expandedFamily = nil
                } label: {
                    Image(systemName:"xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Desde / hacia").frame(maxWidth:.infinity,alignment:.leading)
                Text("Llegan").frame(width:75,alignment:.trailing)
                Text("Salen").frame(width:65,alignment:.trailing)
                Text("Balance").frame(width:65,alignment:.trailing)
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(0..<4,id:\.self) { direction in
                let arrival = activity.arrivals[family][direction]
                let departure = activity.departures[family][direction]
                HStack(spacing:4) {
                    Text(names[direction])
                        .frame(maxWidth:.infinity,alignment:.leading)
                    Text(amount(arrival,sign:true))
                        .foregroundStyle(arrival>0 ? Color.green : Color.secondary)
                        .frame(width:75,alignment:.trailing)
                    Text(amount(departure))
                        .frame(width:65,alignment:.trailing)
                    Text(amount(arrival-departure,sign:true))
                        .frame(width:65,alignment:.trailing)
                }
                .font(.caption.monospacedDigit())
            }
            Divider()
            HStack {
                Text("Total").bold().frame(maxWidth:.infinity,alignment:.leading)
                Text(amount(activity.arrived(family),sign:true))
                    .frame(width:75,alignment:.trailing)
                Text(amount(activity.departed(family)))
                    .frame(width:65,alignment:.trailing)
                Text(amount(activity.arrived(family)-activity.departed(family),sign:true))
                    .frame(width:65,alignment:.trailing)
            }
            .font(.caption.monospacedDigit())
            Text("Llegan del norte, sur, este u oeste; salen hacia esas direcciones. Sin desplazamientos diagonales.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(colors[family].opacity(0.08),
                    in:RoundedRectangle(cornerRadius:12))
    }
}