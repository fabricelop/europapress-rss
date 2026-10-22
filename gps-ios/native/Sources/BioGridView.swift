import SwiftUI
import MapKit

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
        if snapshot?.sourceFingerprint == fingerprint { return }
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(BioGridSnapshot.self, from: data),
           saved.sourceFingerprint == fingerprint {
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

private struct BioGridTile: Identifiable {
    let cell: Cell
    let counts: [Int64]
    let family: Int
    var id: String { cell.id }
}

struct BioGridView: View {
    @ObservedObject var model: TimeModel
    @StateObject private var engine = BioGridController()
    @AppStorage("biogrid.opacity") private var opacity = 0.75
    @State private var camera: MapCameraPosition = .automatic
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude:40.4168,longitude:-3.7038),
                                                   span:MKCoordinateSpan(latitudeDelta:0.018,longitudeDelta:0.018))
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

    private var visibleTiles: [BioGridTile] {
        guard let snapshot = engine.snapshot else { return [] }
        let halfLat = region.span.latitudeDelta * 0.55
        let halfLon = region.span.longitudeDelta * 0.55
        var result: [BioGridTile] = []
        for (key, counts) in snapshot.populations {
            let pieces = key.split(separator: ":")
            guard pieces.count == 2, let row = Int(pieces[0]), let col = Int(pieces[1]) else { continue }
            let cell = Cell(row:row,column:col)
            let coordinate = Grid.center(cell)
            guard abs(coordinate.latitude - region.center.latitude) <= halfLat,
                  abs(coordinate.longitude - region.center.longitude) <= halfLon else { continue }
            guard let maximum = counts.max(), maximum > 0,
                  let family = counts.firstIndex(of:maximum) else { continue }
            result.append(BioGridTile(cell:cell,counts:counts,family:family))
            if result.count >= 2_000 { break } // Sin agrupar; limita solo la renderización.
        }
        return result.sorted { $0.id < $1.id }
    }

    private func compact(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format:"%.2fM",Double(n)/1_000_000) }
        if n >= 1_000 { return String(format:"%.1fK",Double(n)/1_000) }
        return String(n)
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
        .onAppear {
            region = model.data.camera.region
            camera = .region(region)
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
        MapReader { proxy in
            Map(position:$camera) {
                ForEach(visibleTiles) { tile in
                    MapPolygon(coordinates:Grid.polygon(tile.cell))
                        .foregroundStyle(palette[tile.family].opacity(
                            highlighted == nil || highlighted == tile.family ? opacity : opacity * 0.16))
                        .stroke(.black.opacity(0.25),lineWidth:0.45)
                }
                if region.span.latitudeDelta < 0.012 {
                    ForEach(visibleTiles) { tile in
                        Annotation("", coordinate: Grid.center(tile.cell)) {
                            Text("\(BioGridEngine.letters[tile.family]) \(compact(tile.counts[tile.family]))")
                                .font(.system(size:9,weight:.bold))
                                .foregroundStyle(.black)
                                .allowsHitTesting(false)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            .onMapCameraChange(frequency:.onEnd) { context in region = context.region }
            .onTapGesture { point in
                if let location = proxy.convert(point, from:.local) {
                    let cell = Grid.cell(latitude:location.latitude,longitude:location.longitude)
                    if snapshot.populations[cell.id] != nil { chosen = cell }
                }
            }
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
        .frame(maxHeight:270)
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
