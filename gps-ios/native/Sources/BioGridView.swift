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
        return base.appendingPathComponent("biogrid-derived-v3.json")
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
    @State private var showRivalries = false
    @State private var showClassification = false
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

    /// La fuente es el GPS existente. El segundo vivo es una proyección
    /// visual hasta la siguiente confirmación GPS, nunca una escritura.
    private func birthProgress(cell:Cell,snapshot:BioGridSnapshot,now:Date) -> BioGridLiveBirth {
        BioGridBirthTicker.project(
            remainder:snapshot.remainingSeconds[cell.id] ?? 0,
            sourceEnd:snapshot.lastIntervalEnds[cell.id],
            visitStart:model.currentVisitStart ?? model.data.gpsRest?.startedAt,
            latestFix:model.lastGPSFix,
            now:now,
            resting:model.isResting)
    }

    private func predictedBirths(cell:Cell,snapshot:BioGridSnapshot) -> Int64 {
        guard engine.historicalDate == nil, activeCell == cell else { return 0 }
        return birthProgress(cell:cell,snapshot:snapshot,now:clock).provisionalBirths
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
        .onReceive(Timer.publish(every:5,on:.main,in:.common).autoconnect()) { date in
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
                BioGridEventsSheet(events:cycleEvents(snapshot),colors:palette,
                    placeName:{ key in self.readablePlace(key) },
                    populationAfter:{ event in self.eventPopulation(event,snapshot:snapshot) }) { cell in
                        showEvents = false
                        jump(cell)
                    }
            }
        }
        .sheet(isPresented:$showRivalries) {
            if let snapshot = displayed {
                rivalriesSheet(snapshot)
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
        TimelineView(.periodic(from:.now,by:1)) { timeline in
            let now = timeline.date
            VStack(alignment:.leading,spacing:7) {
                HStack {
                    Label("Mi cuadrícula",systemImage:"location.circle.fill")
                        .font(.headline)
                    Spacer()
                    if let cell = activeCell {
                        Button("Centrar") { jump(cell) }.font(.caption)
                    } else {
                        Text("Ubicación no disponible")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let cell = activeCell {
                    let progress = birthProgress(cell:cell,snapshot:snapshot,now:now)
                    let provisional = progress.provisionalBirths
                    let countsBase = snapshot.populations[cell.id] ?? Array(repeating:0,count:7)
                    let totalToday = snapshot.todayBirths[cell.id]?.reduce(0,+) ?? 0
                    let projectedCounts = countsBase.enumerated().map { index, amount -> Int64 in
                        amount + (index == activeFamily ? provisional : 0)
                    }
                    let highest = projectedCounts.max() ?? 0
                    let winner = projectedCounts.firstIndex(of:highest) ?? activeFamily
                    let currentLetter = BioGridEngine.letters[activeFamily]
                    HStack(spacing:9) {
                        Text(BioGridEngine.letters[winner])
                            .bold().frame(width:28,height:28)
                            .background(palette[winner],in:RoundedRectangle(cornerRadius:5))
                            .foregroundStyle(.black)
                        VStack(alignment:.leading,spacing:2) {
                            Text("\(highest.formatted()) bacterias · familia dominante")
                                .font(.subheadline.weight(.semibold))
                            Text("+\(totalToday + provisional) nacidas hoy · familia \(currentLetter)")
                                .font(.caption).foregroundStyle(.green)
                        }
                        Spacer(minLength:0)
                    }
                    HStack {
                        Text(progress.running ? "Próxima bacteria \(currentLetter) +1" :
                            "Cronómetro detenido · sin GPS reciente")
                            .font(.caption)
                        Spacer()
                        Text(String(format:"%02d:%02d",
                            progress.secondsRemaining/60,progress.secondsRemaining%60))
                            .font(.system(.headline,design:.rounded).monospacedDigit())
                    }
                    ProgressView(value:progress.secondsAccumulated,total:300)
                        .tint(palette[activeFamily])
                    if provisional > 0 {
                        Text("+\(provisional) nacimiento\(provisional == 1 ? "" : "s") pendiente\(provisional == 1 ? "" : "s") de confirmación GPS")
                            .font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text("El contador avanza en directo; el tiempo definitivo lo confirma el GPS.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Se utiliza el seguimiento de Mi Mapa del Tiempo, sin activar un GPS adicional.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .background(Color.blue.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
        }
    }

    private func controls(_ snapshot:BioGridSnapshot) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                if engine.historicalDate == nil {
                    liveSection(snapshot)
                } else {
                    HStack {
                        Text("Estado histórico: \(engine.historicalDate!.formatted(date:.abbreviated,time:.omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Volver a hoy") { engine.showPresent() }
                    }
                }
                BioGridDailySummary(
                    snapshot:snapshot,
                    lastCycle:cycle(snapshot),
                    birthsToday:snapshot.todayBirths.values.reduce(Int64(0)) {
                        $0 + $1.reduce(0,+)
                    } + (activeCell.flatMap { predictedBirths(cell:$0,snapshot:snapshot) } ?? 0))
                HStack(spacing:7) {
                    Button { showEvents = true } label: {
                        Label("Crónica",systemImage:"newspaper")
                            .frame(maxWidth:.infinity)
                    }
                    Button { showRivalries = true } label: {
                        Label("Rivalidades",systemImage:"flag.2.crossed")
                            .frame(maxWidth:.infinity)
                    }
                    Button { showCharts = true } label: {
                        Label("Evolución",systemImage:"chart.xyaxis.line")
                            .frame(maxWidth:.infinity)
                    }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                DisclosureGroup("Clasificación de las siete familias",
                                isExpanded:$showClassification) {
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
                        Button {
                            highlighted = highlighted == family.family ? nil : family.family
                        } label: {
                            HStack(spacing:8) {
                                Text(BioGridEngine.letters[family.family]).bold()
                                    .frame(width:25,height:25)
                                    .background(palette[family.family],
                                                in:RoundedRectangle(cornerRadius:5))
                                    .foregroundStyle(.black)
                                Text("\(family.population.formatted()) bacterias")
                                Spacer()
                                Text("\(family.territory.formatted()) casillas")
                                    .foregroundStyle(.secondary)
                            }.font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Text("Transparencia").font(.caption)
                    Slider(value:$opacity,in:0.3...1.0)
                    Text("\(Int(opacity*100)) %")
                        .font(.caption.monospacedDigit()).frame(width:40)
                }
                Button("Consultar informe completo") { showReport = true }
                    .font(.caption)
                Text("Simulación local · solo usa el GPS existente · cuadrículas independientes.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(11)
        }
        .frame(maxHeight:350)
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

    private func readablePlace(_ key:String)->String {
        let cell = self.cell(from:key)
        return BioGridDailyInsights.location(cell,
            zoneName:model.primaryZone(for:cell)?.name,
            explicitName:model.data.names[key],
            near:model.current?.coordinate)
    }

    private func eventPopulation(_ event:BioGridTerritoryEvent,
                                 snapshot:BioGridSnapshot)->Int64 {
        let history = snapshot.cellHistory[event.cellKey] ?? []
        let counts = history.last(where: { $0.date <= event.date })?.counts
            ?? snapshot.populations[event.cellKey] ?? Array(repeating:0,count:7)
        return counts.indices.contains(event.family) ? counts[event.family] : 0
    }

    private func rivalriesSheet(_ snapshot:BioGridSnapshot)->some View {
        let hotspots = hotspots(snapshot)
        return NavigationStack {
            List {
                Section {
                    Text("Cada frente es una cuadrícula con dos o más familias. Se muestran primero los enfrentamientos más igualados.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if hotspots.isEmpty {
                    ContentUnavailableView("Sin rivalidades",systemImage:"flag.2.crossed",
                        description:Text("Todavía no hay cuadrículas donde convivan varias familias."))
                }
                Section("\(hotspots.count) territorios disputados") {
                    ForEach(hotspots.prefix(100)) { front in
                        Button {
                            showRivalries = false
                            jump(front.cell)
                        } label: {
                            VStack(alignment:.leading,spacing:6) {
                                HStack {
                                    Text(readablePlace(front.cell.id))
                                        .font(.subheadline.weight(.semibold))
                                        .fixedSize(horizontal:false,vertical:true)
                                    Spacer()
                                    Image(systemName:"scope").foregroundStyle(.indigo)
                                }
                                HStack(spacing:7) {
                                    Text(BioGridEngine.letters[front.leader])
                                        .bold().foregroundStyle(palette[front.leader])
                                    Text("\(front.leaderCount.formatted())")
                                        .monospacedDigit()
                                    Text("contra").foregroundStyle(.secondary)
                                    Text(BioGridEngine.letters[front.opponent])
                                        .bold().foregroundStyle(palette[front.opponent])
                                    Text("\(front.opponentCount.formatted())")
                                        .monospacedDigit()
                                    Spacer()
                                }.font(.subheadline)
                                Text("Diferencia: \((front.leaderCount-front.opponentCount).formatted()) bacterias · sin resultado predeterminado")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical,3)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Rivalidades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button("Cerrar") { showRivalries = false }
                }
            }
        }
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