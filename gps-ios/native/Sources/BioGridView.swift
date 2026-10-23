import SwiftUI
import MapKit
import Combine

@MainActor final class BioGridController: ObservableObject {
    @Published private(set) var snapshot: BioGridSnapshot?
    @Published private(set) var historicalSnapshot: BioGridSnapshot?
    @Published private(set) var historicalDate: Date?
    @Published private(set) var computing = false
    @Published private(set) var computingHistory = false
    @Published private(set) var error: String?
    private var historyRequest = UUID()

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at:base,
            withIntermediateDirectories:true)
        return base.appendingPathComponent("biogrid-derived-v2.json")
    }
    static var madrid: Calendar {
        var cal = Calendar(identifier:.gregorian)
        cal.timeZone = TimeZone(identifier:"Europe/Madrid")!
        return cal
    }

    func refresh(_ intervals:[AssignedInterval]) {
        guard !computing else { return }
        let fingerprint = BioGridEngine.fingerprint(intervals)
        let today = Self.madrid.startOfDay(for:.now)
        if snapshot?.sourceFingerprint == fingerprint && snapshot?.latestProcessed == today { return }
        if let data = try? Data(contentsOf:cacheURL),
           let saved = try? JSONDecoder().decode(BioGridSnapshot.self,from:data),
           saved.sourceFingerprint == fingerprint && saved.latestProcessed == today {
            snapshot = saved
            return
        }
        computing = true
        error = nil
        let target = cacheURL
        let zone = TimeZone.current
        DispatchQueue.global(qos:.userInitiated).async {
            let result = BioGridEngine.simulate(intervals,timezone:zone)
            if let bytes = try? JSONEncoder().encode(result) {
                try? bytes.write(to:target,options:.atomic)
            }
            DispatchQueue.main.async {
                self.snapshot = result
                self.computing = false
                // El historial abierto ya no representa los datos corregidos.
                self.historicalSnapshot = nil
                self.historicalDate = nil
            }
        }
    }

    func showPresent() {
        historyRequest = UUID()
        historicalSnapshot = nil
        historicalDate = nil
        computingHistory = false
    }

    func show(_ chosenDay:Date, intervals:[AssignedInterval]) {
        let cal = Self.madrid
        let selectedDay = cal.startOfDay(for:chosenDay)
        if selectedDay >= cal.startOfDay(for:.now) { showPresent(); return }
        historicalDate = selectedDay
        historicalSnapshot = nil
        computingHistory = true
        let request = UUID()
        historyRequest = request
        let nextDay = cal.date(byAdding:.day,value:1,to:selectedDay)!
        let end = nextDay.addingTimeInterval(-1)
        let zone = TimeZone.current
        DispatchQueue.global(qos:.userInitiated).async {
            let historical = BioGridEngine.simulate(intervals,now:end,timezone:zone)
            DispatchQueue.main.async {
                guard self.historyRequest == request else { return }
                self.historicalSnapshot = historical
                self.computingHistory = false
            }
        }
    }
}

private struct BioGridFront: Identifiable {
    let cell:Cell
    let leader:Int
    let opponent:Int
    let leaderCount:Int64
    let opponentCount:Int64
    var id:String { cell.id }
    var closeness:Double { Double(opponentCount) / Double(max(1,leaderCount)) }
}

struct BioGridView: View {
    @ObservedObject var model: TimeModel
    @StateObject private var engine = BioGridController()
    @AppStorage("biogrid.opacity") private var opacity = 0.75
    @State private var clock = Date()
    @State private var todayMode = false
    @State private var focusCell:Cell?
    @State private var focusToken = 0
    @State private var followPosition = false
    @State private var chosen:Cell?
    @State private var highlighted:Int?
    @State private var territoryRanking = false
    @State private var showReport = false
    @State private var showEvents = false
    @State private var showCharts = false

    private let palette:[Color] = [
        Color(red:0.88,green:0.16,blue:0.18),
        Color(red:0.12,green:0.36,blue:0.92),
        Color(red:0.12,green:0.65,blue:0.23),
        Color(red:1.00,green:0.56,blue:0.02),
        Color(red:0.61,green:0.23,blue:0.78),
        Color(red:0.90,green:0.73,blue:0.00),
        Color(red:0.02,green:0.72,blue:0.79)
    ]

    private var displayed:BioGridSnapshot? {
        engine.historicalSnapshot ?? (engine.historicalDate == nil ? engine.snapshot : nil)
    }

    private var activeCell:Cell? {
        guard engine.historicalDate == nil,let cell = model.activeCell else { return nil }
        if model.isResting { return cell }
        guard model.recording,let age = model.gpsFixAge(now:clock),age <= 180 else { return nil }
        return cell
    }

    private var activeFamily:Int {
        let weekday = Calendar.current.component(.weekday,from:clock)
        return (weekday+5)%7
    }

    // El contador visible puede interpolar hasta la siguiente posición GPS:
    // es provisional y nunca modifica los intervalos originales.
    private func predictedBirths(cell:Cell,snapshot:BioGridSnapshot) -> Int64 {
        guard engine.historicalDate == nil,activeCell == cell else { return 0 }
        let rest = snapshot.remainingSeconds[cell.id,default:0]
        let last = model.data.intervals.last
        let lastConfirmed = last?.cell == cell ? last?.end : nil
        let visitStart = model.currentVisitStart ?? model.data.gpsRest?.startedAt
        let anchor = max(lastConfirmed ?? visitStart ?? clock,
                         visitStart ?? .distantPast)
        let allowedThrough:Date
        if model.isResting {
            allowedThrough = clock
        } else {
            guard let fix = model.lastGPSFix else { return 0 }
            allowedThrough = min(clock,fix.addingTimeInterval(120))
        }
        let provisional = max(0,allowedThrough.timeIntervalSince(anchor))
        return Int64(floor((rest + provisional) / 300.0))
    }

    private func birthCountdown(cell:Cell,snapshot:BioGridSnapshot) -> (seconds:Int,elapsed:Double) {
        let rest = snapshot.remainingSeconds[cell.id,default:0]
        let predicted = predictedBirths(cell:cell,snapshot:snapshot)
        // Predicción + fracción acumulada. Mantener el contador quieto cuando
        // el GPS se interrumpe en lugar de inventar tiempo indefinidamente.
        let last = model.data.intervals.last
        let anchor = max(last?.cell == cell ? last!.end : model.currentVisitStart ?? clock,
                         model.currentVisitStart ?? .distantPast)
        let through:Date
        if model.isResting { through = clock }
        else if let fix = model.lastGPSFix { through = min(clock,fix.addingTimeInterval(120)) }
        else { through = clock }
        let projected = max(0,through.timeIntervalSince(anchor))
        let accumulated = rest + projected
        let elapsed = accumulated.truncatingRemainder(dividingBy:300)
        _ = predicted
        return (max(0,Int(ceil(300 - elapsed))),elapsed)
    }

    private func mapPopulations(_ snapshot:BioGridSnapshot) -> [String:[Int64]] {
        var populations = snapshot.populations
        if let cell = activeCell {
            let projected = predictedBirths(cell:cell,snapshot:snapshot)
            if projected > 0 {
                var counts = populations[cell.id] ?? Array(repeating:0,count:7)
                counts[activeFamily] += projected
                populations[cell.id] = counts
            }
        }
        return populations
    }

    private func birthsForMap(_ snapshot:BioGridSnapshot) -> [String:[Int64]] {
        var births = snapshot.todayBirths
        if let cell = activeCell {
            let projected = predictedBirths(cell:cell,snapshot:snapshot)
            if projected > 0 {
                var counts = births[cell.id] ?? Array(repeating:0,count:7)
                counts[activeFamily] += projected
                births[cell.id] = counts
            }
        }
        return births
    }

    private func cycle(_ snapshot:BioGridSnapshot) -> BioGridDay? {
        let today = BioGridController.madrid.startOfDay(for:
            engine.historicalDate ?? clock)
        return snapshot.days.last(where: { $0.date < today })
    }

    private func cycleEvents(_ snapshot:BioGridSnapshot) -> [BioGridTerritoryEvent] {
        guard let day = cycle(snapshot)?.date else { return [] }
        return snapshot.territoryEvents.filter { $0.date == day }
    }

    private func hotspots(_ snapshot:BioGridSnapshot) -> [BioGridFront] {
        var result:[BioGridFront] = []
        for (key, counts) in snapshot.populations {
            let order = (0..<min(counts.count,7)).filter { counts[$0] > 0 }
                .sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0] > counts[$1] }
            guard order.count > 1 else { continue }
            let p = key.split(separator:":")
            guard p.count == 2,let r = Int(p[0]),let c = Int(p[1]) else { continue }
            result.append(BioGridFront(cell:Cell(row:r,column:c),
                leader:order[0],opponent:order[1],
                leaderCount:counts[order[0]],opponentCount:counts[order[1]]))
        }
        return result.sorted {
            $0.closeness == $1.closeness ?
                $0.leaderCount+$0.opponentCount > $1.leaderCount+$1.opponentCount :
                $0.closeness > $1.closeness
        }
    }

    private func jump(_ cell:Cell) {
        focusCell = cell
        focusToken += 1
    }

    private func centerOnMe() {
        guard let activeCell else { return }
        jump(activeCell)
    }

    var body:some View {
        VStack(spacing:0) {
            if engine.computing || engine.computingHistory {
                HStack(spacing:8) {
                    ProgressView()
                    Text(engine.computingHistory ? "Recuperando el estado histórico…" :
                        "Calculando BIOGRID a partir del historial GPS…")
                        .font(.caption)
                }
                .frame(maxWidth:.infinity).padding(8)
            }
            if let snapshot = displayed {
                if snapshot.populations.isEmpty && activeCell == nil {
                    ContentUnavailableView("Sin colonias todavía",systemImage:"circle.hexagongrid",
                        description:Text("Cada cinco minutos de estancia confirmada nace una bacteria."))
                } else {
                    mapToolbar(snapshot)
                    mapPanel(snapshot)
                    controls(snapshot)
                }
            } else if !engine.computing && !engine.computingHistory {
                ContentUnavailableView("BIOGRID",systemImage:"circle.hexagongrid",
                    description:Text("Abre BIOGRID para calcular su evolución local."))
            }
        }
        .navigationTitle("BIOGRID")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            clock = .now
            engine.refresh(model.data.intervals)
        }
        .onReceive(Timer.publish(every:1,on:.main,in:.common).autoconnect()) { date in
            clock = date
        }
        .onReceive(Timer.publish(every:15,on:.main,in:.common).autoconnect()) { _ in
            engine.refresh(model.data.intervals)
        }
        .onChange(of:model.data.intervals.count) { _,_ in
            engine.refresh(model.data.intervals)
        }
        .onChange(of:model.activeCell?.id) { _,_ in
            if followPosition { centerOnMe() }
        }
        .sheet(item:$chosen) { cell in
            let selected = displayed ?? engine.snapshot
            if let snapshot = selected {
                BioGridCellSheet(cell:cell,
                    populations:mapPopulations(snapshot)[cell.id] ?? Array(repeating:0,count:7),
                    bornToday:birthsForMap(snapshot)[cell.id] ?? Array(repeating:0,count:7),
                    history:engine.snapshot?.cellHistory[cell.id] ?? [],
                    colors:palette)
                    .presentationDetents([.medium,.large])
            }
        }
        .sheet(isPresented:$showReport) {
            if let snapshot = displayed {
                BioGridReportSheet(report:cycle(snapshot) ?? snapshot.days.last,colors:palette)
                    .presentationDetents([.medium,.large])
            }
        }
        .sheet(isPresented:$showEvents) {
            if let snapshot = displayed {
                BioGridEventsSheet(events:cycleEvents(snapshot),colors:palette) { cell in
                    showEvents = false
                    jump(cell)
                }
            }
        }
        .sheet(isPresented:$showCharts) {
            if let snapshot = engine.snapshot {
                BioGridChartsView(history:snapshot.historical,colors:palette) { date in
                    showCharts = false
                    engine.show(date,intervals:model.data.intervals)
                }
            }
        }
    }

    private func mapToolbar(_ snapshot:BioGridSnapshot) -> some View {
        HStack(spacing:10) {
            Picker("Poblaciones",selection:$todayMode) {
                Text("Todo").tag(false)
                Text("Hoy").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth:205)
            if let date = engine.historicalDate {
                Button {
                    engine.showPresent()
                } label: {
                    Label("Presente",systemImage:"arrow.uturn.backward")
                        .font(.caption)
                }.buttonStyle(.bordered)
                .help("Fecha histórica: \(date.formatted(date:.abbreviated,time:.omitted))")
            }
            Spacer(minLength:0)
            Text(todayMode ? "Nacimientos del día" : "Todas las colonias")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal,11).padding(.vertical,5)
    }

    private func mapPanel(_ snapshot:BioGridSnapshot) -> some View {
        let populations = mapPopulations(snapshot)
        let births = birthsForMap(snapshot)
        let events = Dictionary(cycleEvents(snapshot).map { event in
            (event.cellKey,event.kind == .conquest ? "⚑" :
                event.kind == .recolonization ? "○" : "●")
        },uniquingKeysWith: { first,_ in first })
        let visualKey = "\(snapshot.sourceFingerprint)|\(snapshot.latestProcessed?.timeIntervalSince1970 ?? 0)|\(engine.historicalDate?.timeIntervalSince1970 ?? 0)|\(predictedBirths(cell:activeCell ?? Cell(row:0,column:0),snapshot:snapshot))|\(todayMode)"
        return BioGridStableMap(populations:populations,
            fingerprint:visualKey,todayBirths:births,todayMode:todayMode,
            recentEvents:events,currentPosition:model.current?.coordinate,
            palette:palette,opacity:opacity,highlighted:highlighted,
            initialRegion:model.data.camera.region,focusCell:focusCell,
            focusToken:focusToken) { cell in
                chosen = cell
            }
            .frame(maxHeight:.infinity)
            .overlay(alignment:.topLeading) {
                VStack(alignment:.leading,spacing:5) {
                    Text("\(snapshot.populations.count.formatted()) cuadrículas colonizadas")
                        .font(.caption.bold())
                    if let date = engine.historicalDate {
                        Text(date.formatted(date:.abbreviated,time:.omitted))
                            .font(.caption2)
                    }
                }
                .padding(8)
                .background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                .padding(9)
            }
            .overlay(alignment:.topTrailing) {
                VStack(spacing:8) {
                    Button { centerOnMe() } label: {
                        Image(systemName:"location.fill")
                            .font(.title3)
                            .frame(width:44,height:44)
                    }
                    .disabled(activeCell == nil)
                    .accessibilityLabel("Centrar en mi cuadrícula actual")
                    .background(.regularMaterial,in:Circle())
                    Button {
                        followPosition.toggle()
                        if followPosition { centerOnMe() }
                    } label: {
                        Image(systemName:followPosition ? "location.north.line.fill" : "location.north.line")
                            .font(.title3)
                            .frame(width:44,height:44)
                    }
                    .disabled(activeCell == nil)
                    .accessibilityLabel("Seguir mi cuadrícula")
                    .background(.regularMaterial,in:Circle())
                }
                .buttonStyle(.plain)
                .padding(9)
            }
    }

    private func liveSection(_ snapshot:BioGridSnapshot) -> some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Label("Mi cuadrícula",systemImage:"location.circle.fill")
                    .font(.headline)
                Spacer()
                if let cell = activeCell {
                    Button("Centrar") { jump(cell) }.font(.caption)
                } else {
                    Text("Sin posición reciente").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let cell = activeCell {
                let next = birthCountdown(cell:cell,snapshot:snapshot)
                let confirmed = snapshot.todayBirths[cell.id]?.reduce(Int64(0),+) ?? 0
                let extra = predictedBirths(cell:cell,snapshot:snapshot)
                let counts = mapPopulations(snapshot)[cell.id] ?? Array(repeating:0,count:7)
                let winner = counts.max() ?? 0
                let leader = counts.firstIndex(of:winner) ?? activeFamily
                HStack(spacing:9) {
                    Text(BioGridEngine.letters[leader])
                        .bold().frame(width:28,height:28)
                        .background(palette[leader],in:RoundedRectangle(cornerRadius:5))
                        .foregroundStyle(.black)
                    Text("\(winner.formatted()) bacterias").font(.headline)
                    Spacer()
                    Text("+\(confirmed+extra) hoy")
                        .font(.subheadline.bold()).foregroundStyle(.green)
                }
                HStack {
                    Text("Siguiente \(BioGridEngine.letters[activeFamily]) +1")
                        .font(.caption)
                    Spacer()
                    Text(String(format:"%02d:%02d",next.seconds/60,next.seconds%60))
                        .font(.subheadline.monospacedDigit().bold())
                }
                ProgressView(value:next.elapsed,total:300)
                    .tint(palette[activeFamily])
                if extra > 0 {
                    Text("\(extra) nacimiento(s) provisional(es) hasta confirmar GPS")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text("Activa el seguimiento GPS habitual y vuelve a BIOGRID. No se inicia otro GPS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(Color.blue.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
    }

    private func controls(_ snapshot:BioGridSnapshot) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                if engine.historicalDate == nil {
                    liveSection(snapshot)
                } else {
                    HStack {
                        Text("Consultando un día histórico")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Volver a hoy") { engine.showPresent() }
                    }
                }
                activitySection(snapshot)
                HStack {
                    Button { showCharts = true } label: {
                        Label("Gráficas y rivalidades",systemImage:"chart.xyaxis.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    Spacer()
                    Button { showEvents = true } label: {
                        Label("Conquistas",systemImage:"flag")
                    }
                    .buttonStyle(.bordered)
                }
                HStack {
                    Text("Opacidad").font(.caption)
                    Slider(value:$opacity,in:0.3...1.0)
                    Text("\(Int(opacity*100)) %")
                        .font(.caption.monospacedDigit()).frame(width:42)
                }
                HStack {
                    Text("Clasificación").font(.headline)
                    Spacer()
                    Button("Informe diario") { showReport = true }.font(.caption)
                }
                Picker("Orden",selection:$territoryRanking) {
                    Text("Población").tag(false)
                    Text("Territorio").tag(true)
                }.pickerStyle(.segmented)
                let rank = snapshot.ranking().sorted {
                    territoryRanking ? ($0.territory == $1.territory
                        ? $0.population > $1.population : $0.territory > $1.territory)
                        : ($0.population == $1.population
                        ? $0.territory > $1.territory : $0.population > $1.population)
                }
                ForEach(rank,id:\.family) { family in
                    Button { highlighted = highlighted == family.family ? nil : family.family } label: {
                        HStack {
                            Text(BioGridEngine.letters[family.family]).bold()
                                .frame(width:25,height:25)
                                .background(palette[family.family],in:RoundedRectangle(cornerRadius:5))
                                .foregroundStyle(.black)
                            Text("\(family.population.formatted()) bacterias")
                            Spacer()
                            Text("\(family.territory.formatted()) casillas")
                                .foregroundStyle(.secondary)
                        }.font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .opacity(highlighted == nil || highlighted == family.family ? 1 : 0.45)
                }
                Text("Simulación local, sin GPS adicional. Las cuadrículas nunca se agrupan.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(11)
        }
        .frame(maxHeight:370)
    }

    private func activitySection(_ snapshot:BioGridSnapshot) -> some View {
        let fronts = hotspots(snapshot)
        let report = cycle(snapshot)
        let events = cycleEvents(snapshot)
        return VStack(alignment:.leading,spacing:8) {
            HStack {
                Label("Actividad territorial",systemImage:"bolt.heart.fill").font(.headline)
                Spacer()
                Text("\(fronts.count) frentes").font(.caption.bold()).foregroundStyle(.orange)
            }
            if let report {
                HStack(spacing:8) {
                    metric("Conquistas",value:report.conquests.reduce(0,+),icon:"flag.fill")
                    metric("Bajas",value:report.deaths.reduce(0,+),icon:"cross.fill")
                    metric("Colonizaciones",value:report.newCells.reduce(0,+),icon:"square.grid.2x2")
                }
                if !events.isEmpty {
                    HStack {
                        Text("Últimos cambios territoriales").font(.caption.weight(.semibold))
                        Spacer()
                        Button("Ver todos") { showEvents = true }.font(.caption2)
                    }
                    ForEach(Array(events.prefix(3))) { event in
                        Button {
                            jump(cell(from:event.cellKey))
                        } label: {
                            HStack {
                                Image(systemName:event.kind == .conquest ? "flag.fill" :
                                    event.kind == .recolonization ? "circle.dotted" : "circle.fill")
                                    .foregroundStyle(palette[event.family])
                                Text(event.kind == .conquest ? "Conquista" :
                                    event.kind == .recolonization ? "Recolonización" : "Nueva colonia")
                                Spacer()
                                Text("\(BioGridEngine.letters[event.family]) · \(event.cellKey)")
                                    .font(.caption.monospacedDigit())
                                Image(systemName:"scope")
                            }
                        }.buttonStyle(.plain).font(.caption)
                    }
                }
            }
            Text("Frentes con rivalidades más equilibradas")
                .font(.caption.weight(.semibold))
            ForEach(fronts.prefix(3)) { front in
                Button { jump(front.cell) } label: {
                    HStack {
                        Text(BioGridEngine.letters[front.leader])
                            .bold().foregroundStyle(palette[front.leader])
                        Text("\(front.leaderCount) contra \(front.opponentCount)")
                            .font(.subheadline.monospacedDigit())
                        Text(BioGridEngine.letters[front.opponent])
                            .bold().foregroundStyle(palette[front.opponent])
                        Spacer()
                        Text("\(Int(front.closeness*100)) %")
                            .foregroundStyle(.secondary)
                        Image(systemName:"scope").foregroundStyle(.orange)
                    }
                }.buttonStyle(.plain)
            }
            if fronts.isEmpty {
                Text("Todavía no hay frentes disputados.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
    }

    private func metric(_ name:String,value:Int64,icon:String) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Label(name,systemImage:icon)
                .font(.caption2).foregroundStyle(.secondary)
            Text(value.formatted()).font(.headline.monospacedDigit())
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }

    private func cell(from key:String) -> Cell {
        let values = key.split(separator:":")
        return Cell(row:Int(values.first ?? "") ?? 0,
                    column:Int(values.last ?? "") ?? 0)
    }
}

private struct BioGridCellSheet: View {
    let cell:Cell
    let populations:[Int64]
    let bornToday:[Int64]
    let history:[BioGridCellPoint]
    let colors:[Color]
    @State private var showHistory = false
    var body:some View {
        NavigationStack {
            List {
                Section("Población actual y nacimientos de hoy") {
                    ForEach(0..<7,id:\.self) { i in
                        HStack {
                            Circle().fill(colors[i]).frame(width:15,height:15)
                            Text(BioGridEngine.letters[i]).font(.headline)
                            Spacer()
                            Text(populations[i].formatted()).monospacedDigit()
                            if bornToday[i] > 0 {
                                Text("+\(bornToday[i])").foregroundStyle(.green)
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
                Section {
                    Button { showHistory = true } label: {
                        Label("Ver evolución de esta cuadrícula",systemImage:"chart.xyaxis.line")
                    }
                }
            }
            .navigationTitle("Cuadrícula \(cell.id)")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$showHistory) {
                BioGridCellChartView(cell:cell,history:history,colors:colors)
            }
        }
    }
}

private struct BioGridReportSheet:View {
    let report:BioGridDay?
    let colors:[Color]
    private func total(_ a:[Int64]) -> String { a.reduce(0,+).formatted() }
    var body:some View {
        NavigationStack {
            List {
                if let report {
                    Section("Resumen · \(report.date.formatted(date:.abbreviated,time:.omitted))") {
                        LabeledContent("Nacimientos",value:total(report.births))
                        LabeledContent("Emigraciones",value:total(report.migrated))
                        LabeledContent("Bajas",value:total(report.deaths))
                        LabeledContent("Colonizaciones",value:total(report.newCells))
                        LabeledContent("Conquistas",value:total(report.conquests))
                    }
                    Section("Por familia: nacimientos / bajas") {
                        ForEach(0..<7,id:\.self) { i in
                            HStack {
                                Circle().fill(colors[i]).frame(width:13,height:13)
                                Text(BioGridEngine.letters[i])
                                Spacer()
                                Text("+\(report.births[i].formatted()) −\(report.deaths[i].formatted())")
                                    .monospacedDigit()
                            }
                        }
                    }
                } else { Text("Aún no hay informes diarios.") }
            }.navigationTitle("Informe BIOGRID")
        }
    }
}