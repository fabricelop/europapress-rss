import SwiftUI
import MapKit
import Combine

@MainActor final class BioGridController: ObservableObject {
    @Published private(set) var snapshot: BioGridSnapshot?
    @Published private(set) var computing = false
    @Published private(set) var error: String?

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("biogrid-derived-v1.json")
    }

    func refresh(_ intervals: [AssignedInterval]) {
        guard !computing else { return }
        let fingerprint = BioGridEngine.fingerprint(intervals)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let currentDay = calendar.startOfDay(for: .now)
        if snapshot?.sourceFingerprint == fingerprint && snapshot?.latestProcessed == currentDay { return }
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(BioGridSnapshot.self, from: data),
           saved.sourceFingerprint == fingerprint && saved.latestProcessed == currentDay {
            snapshot = saved
            return
        }
        computing = true
        error = nil
        let destination = cacheURL
        let localTimeZone = TimeZone.current
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BioGridEngine.simulate(intervals, timezone: localTimeZone)
            if let bytes = try? JSONEncoder().encode(result) {
                try? bytes.write(to: destination, options: .atomic)
            }
            DispatchQueue.main.async {
                self.snapshot = result
                self.computing = false
            }
        }
    }
}

private struct BioGridFront: Identifiable {
    let cell: Cell
    let dominant: Int
    let rival: Int
    let dominantCount: Int64
    let rivalCount: Int64
    let priority: Double
    var id: String { cell.id }
}

struct BioGridView: View {
    @ObservedObject var model: TimeModel
    @StateObject private var engine = BioGridController()
    @AppStorage("biogrid.opacity") private var opacity = 0.75
    @State private var focusCell: Cell?
    @State private var focusToken = 0
    @State private var chosen: Cell?
    @State private var highlighted: Int?
    @State private var territoryRanking = false
    @State private var showReport = false

    private let palette: [Color] = [
        Color(red:0.88,green:0.16,blue:0.18), // L: rojo
        Color(red:0.12,green:0.36,blue:0.92), // M: azul
        Color(red:0.12,green:0.65,blue:0.23), // X: verde
        Color(red:1.00,green:0.56,blue:0.02), // J: naranja
        Color(red:0.61,green:0.23,blue:0.78), // V: violeta
        Color(red:0.90,green:0.73,blue:0.00), // S: amarillo
        Color(red:0.02,green:0.72,blue:0.79)  // D: cian
    ]

    private func fronts(_ snapshot: BioGridSnapshot) -> [BioGridFront] {
        var results: [BioGridFront] = []
        for (key, populations) in snapshot.populations {
            let ranked = (0..<min(populations.count,7))
                .filter { populations[$0] > 0 }
                .sorted { populations[$0] == populations[$1] ? $0 < $1 : populations[$0] > populations[$1] }
            guard ranked.count >= 2 else { continue }
            let parts = key.split(separator: ":")
            guard parts.count == 2, let row = Int(parts[0]), let col = Int(parts[1]) else { continue }
            let a = ranked[0], b = ranked[1]
            let total = populations.reduce(Int64(0),+)
            let closeness = Double(populations[b]) / Double(populations[a])
            let priority = closeness * 100 + log10(Double(total)+1) * 6
            results.append(BioGridFront(cell:Cell(row:row,column:col),
                dominant:a,rival:b,dominantCount:populations[a],
                rivalCount:populations[b],priority:priority))
        }
        return results.sorted {
            $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority
        }
    }

    private func lastBattleReport(_ snapshot: BioGridSnapshot) -> BioGridDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier:"Europe/Madrid")!
        let today = calendar.startOfDay(for:Date())
        return snapshot.days.last(where: { $0.date < today })
    }

    var body: some View {
        VStack(spacing:0) {
            if engine.computing {
                HStack(spacing:10) {
                    ProgressView()
                    Text("Calculando BIOGRID a partir del historial GPS…")
                        .font(.footnote)
                }.frame(maxWidth:.infinity).padding(12)
            }
            if let snapshot = engine.snapshot {
                if snapshot.populations.isEmpty {
                    ContentUnavailableView("Sin bacterias todavía", systemImage:"circle.hexagongrid",
                         description:Text("Cada cinco minutos de tiempo confirmado en una cuadrícula nace una bacteria."))
                } else {
                    mapPanel(snapshot)
                    controls(snapshot)
                }
            } else if !engine.computing {
                ContentUnavailableView("BIOGRID", systemImage:"circle.hexagongrid",
                     description:Text("Abre BIOGRID para calcular la simulación local."))
            }
        }
        .navigationTitle("BIOGRID")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { engine.refresh(model.data.intervals) }
        .onReceive(Timer.publish(every: 120, on: .main, in: .common).autoconnect()) { _ in
            engine.refresh(model.data.intervals)
        }
        .onChange(of: model.data.intervals.count) { _, _ in engine.refresh(model.data.intervals) }
        .sheet(item:$chosen) { cell in
            if let populations = engine.snapshot?.populations[cell.id] {
                BioGridCellSheet(cell:cell, populations:populations, colors:palette)
                    .presentationDetents([.medium])
            }
        }
        .sheet(isPresented:$showReport) {
            if let snapshot = engine.snapshot {
                BioGridReportSheet(report:snapshot.days.last,colors:palette)
                    .presentationDetents([.medium,.large])
            }
        }
    }

    private func mapPanel(_ snapshot: BioGridSnapshot) -> some View {
        BioGridStableMap(populations:snapshot.populations,
            fingerprint:snapshot.sourceFingerprint,
            palette:palette,opacity:opacity,highlighted:highlighted,
            initialRegion:model.data.camera.region,
            focusCell:focusCell,focusToken:focusToken) { cell in
                chosen = cell
            }
            .frame(maxHeight:.infinity)
            .overlay(alignment:.topLeading) {
                Text("\(snapshot.populations.count.formatted()) cuadrículas colonizadas")
                    .font(.caption.bold()).padding(8)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                    .padding(9)
            }
    }

    private func controls(_ snapshot: BioGridSnapshot) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:11) {
                activitySection(snapshot)
                HStack {
                    Text("Opacidad").font(.caption)
                    Slider(value:$opacity,in:0.3...1.0)
                    Text("\(Int(opacity*100)) %").font(.caption.monospacedDigit()).frame(width:44)
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
                    territoryRanking ? ($0.territory == $1.territory ? $0.population > $1.population : $0.territory > $1.territory)
                                     : ($0.population == $1.population ? $0.territory > $1.territory : $0.population > $1.population)
                }
                ForEach(rank,id:\.family) { family in
                    Button {
                        highlighted = highlighted == family.family ? nil : family.family
                    } label: {
                        HStack {
                            Text(BioGridEngine.letters[family.family]).bold()
                                .frame(width:24,height:24)
                                .background(palette[family.family],in:RoundedRectangle(cornerRadius:5))
                                .foregroundStyle(.black)
                            Text("\(family.population.formatted()) bacterias")
                            Spacer()
                            Text("\(family.territory.formatted()) casillas")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .opacity(highlighted == nil || highlighted == family.family ? 1 : 0.45)
                }
                Text("Simulación local · ninguna cuadrícula se agrupa · las bacterias solo nacen del tiempo GPS confirmado.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(12)
        }
        .frame(maxHeight:310)
    }

    private func activitySection(_ snapshot: BioGridSnapshot) -> some View {
        let todayFronts = fronts(snapshot)
        let night = lastBattleReport(snapshot)
        return VStack(alignment:.leading,spacing:8) {
            HStack {
                Label("BIOGRID en movimiento",systemImage:"bolt.heart.fill")
                    .font(.headline)
                Spacer()
                Text("\(todayFronts.count) frentes")
                    .font(.caption.bold())
                    .foregroundStyle(todayFronts.isEmpty ? Color.secondary : Color.orange)
            }
            if let night {
                let conquests = night.conquests.reduce(0,+)
                let deaths = night.deaths.reduce(0,+)
                let arrivals = night.newCells.reduce(0,+)
                HStack(spacing:10) {
                    dailyMetric("Conquistas",value:conquests,symbol:"flag.fill")
                    dailyMetric("Bajas",value:deaths,symbol:"cross.fill")
                    dailyMetric("Nuevas",value:arrivals,symbol:"circle.grid.2x2.fill")
                }
                Text("Último ciclo completo · \(night.date.formatted(date:.abbreviated,time:.omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !todayFronts.isEmpty {
                Text("Frentes disputados · toca uno para localizarlo")
                    .font(.caption.weight(.semibold))
                ForEach(todayFronts.prefix(3)) { front in
                    Button {
                        focusCell = front.cell
                        focusToken += 1
                    } label: {
                        HStack(spacing:9) {
                            Text(BioGridEngine.letters[front.dominant])
                                .font(.caption.bold())
                                .frame(width:22,height:22)
                                .background(palette[front.dominant],in:RoundedRectangle(cornerRadius:4))
                                .foregroundStyle(.black)
                            Text("\(front.dominantCount) contra \(front.rivalCount)")
                                .font(.subheadline.weight(.medium))
                            Text(BioGridEngine.letters[front.rival])
                                .font(.caption.bold())
                                .foregroundStyle(palette[front.rival])
                            Spacer()
                            Image(systemName:"scope").foregroundStyle(.orange)
                        }
                    }.buttonStyle(.plain)
                }
            } else {
                Text("Todavía no hay cuadrículas disputadas por varias familias.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Tu influencia es real: cinco minutos en una cuadrícula añaden una bacteria de la familia del día.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(11)
        .background(Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
    }

    private func dailyMetric(_ name:String,value:Int64,symbol:String) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Label(name,systemImage:symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value.formatted()).font(.headline.monospacedDigit())
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }

}

private struct BioGridCellSheet: View {
    let cell: Cell
    let populations: [Int64]
    let colors: [Color]
    var body: some View {
        NavigationStack {
            List(0..<7,id:\.self) { i in
                HStack {
                    Circle().fill(colors[i]).frame(width:16,height:16)
                    Text(BioGridEngine.letters[i]).font(.headline)
                    Spacer()
                    Text(populations[i].formatted()).monospacedDigit()
                }
            }
            .navigationTitle("Cuadrícula \(cell.id)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct BioGridReportSheet: View {
    let report: BioGridDay?
    let colors: [Color]
    private func total(_ values:[Int64])->String { values.reduce(0,+).formatted() }
    var body: some View {
        NavigationStack {
            List {
                if let report {
                    Section("Resumen") {
                        LabeledContent("Nacimientos",value:total(report.births))
                        LabeledContent("Emigraciones",value:total(report.migrated))
                        LabeledContent("Muertes en combate",value:total(report.deaths))
                        LabeledContent("Primeras colonizaciones",value:total(report.newCells))
                        LabeledContent("Conquistas",value:total(report.conquests))
                    }
                    Section("Por familia · nacimientos / bajas") {
                        ForEach(0..<7,id:\.self) { i in
                            HStack {
                                Circle().fill(colors[i]).frame(width:13,height:13)
                                Text(BioGridEngine.letters[i])
                                Spacer()
                                Text("+\(report.births[i].formatted())  −\(report.deaths[i].formatted())")
                                    .monospacedDigit()
                            }
                        }
                    }
                } else { Text("No existen informes todavía.") }
            }
            .navigationTitle("Informe BIOGRID")
        }
    }
}
