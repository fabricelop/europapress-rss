import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers
import CryptoKit
import Foundation

// iOS 17+ proof-of-concept. All coordinates are stored locally.
// Background location requires user permission and must be tested on an actual iPhone.
struct Cell: Hashable, Codable, Identifiable {
    let row: Int
    let column: Int
    var id: String { "\(row):\(column)" }
}
enum Grid {
    static let radius = 6_378_137.0
    static let latitudeStep = 100.0 / radius * 180.0 / .pi
    static func cell(latitude: Double, longitude: Double) -> Cell {
        let lat = min(89.999, max(-89.999, latitude))
        let lon = min(179.999999, max(-180, longitude))
        let row = Int(floor((lat + 90) / latitudeStep))
        let mid = -90 + (Double(row) + 0.5) * latitudeStep
        let lonStep = latitudeStep / max(0.001, cos(mid * .pi / 180))
        return Cell(row: row, column: Int(floor((lon + 180) / lonStep)))
    }
    static func polygon(_ c: Cell) -> [CLLocationCoordinate2D] {
        let south = -90 + Double(c.row) * latitudeStep
        let north = south + latitudeStep
        let lonStep = latitudeStep / max(0.001, cos((south + north) * .pi / 360))
        let west = -180 + Double(c.column) * lonStep
        let east = west + lonStep
        return [
            .init(latitude: south, longitude: west),
            .init(latitude: south, longitude: east),
            .init(latitude: north, longitude: east),
            .init(latitude: north, longitude: west)
        ]
    }
    static func center(_ c: Cell) -> CLLocationCoordinate2D {
        let vertices = polygon(c)
        return .init(latitude: (vertices[0].latitude + vertices[2].latitude) / 2,
                     longitude: (vertices[0].longitude + vertices[2].longitude) / 2)
    }
}
enum DurationFormat {
    // A displayed month is exactly 30 days; these are durations, not calendar dates.
    static func full(_ seconds: TimeInterval) -> String {
        var n = Int(max(0, seconds.rounded(.down)))
        let months = n / 2_592_000; n %= 2_592_000
        let days = n / 86_400; n %= 86_400
        let hours = n / 3_600; n %= 3_600
        let minutes = n / 60; n %= 60
        return "\(months)M-\(days)D-\(hours)H:\(minutes)m:\(n)sg"
    }
    static func small(_ seconds: TimeInterval) -> String {
        let n = Int(max(0, seconds))
        if n >= 2_592_000 { return "\(n / 2_592_000)M" }
        if n >= 86_400 { return "\(n / 86_400)D" }
        if n >= 3_600 { return "\(n / 3_600)H" }
        if n >= 60 { return "\(n / 60)m" }
        return "\(n)sg"
    }
}
struct GPSPoint: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let source: String
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var cell: Cell { Grid.cell(latitude: latitude, longitude: longitude) }
}
struct AssignedInterval: Codable, Identifiable {
    var id = UUID()
    let start: Date
    let end: Date
    let cell: Cell
    let quality: String
    let source: String
    var seconds: TimeInterval { end.timeIntervalSince(start) }
}
struct CameraSave: Codable {
    var latitude: Double = 40.4168
    var longitude: Double = -3.7038
    var latitudeDelta: Double = 0.009
    var longitudeDelta: Double = 0.009
    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: latitude, longitude: longitude),
                           span: .init(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    }
    init() {}
    init(_ r: MKCoordinateRegion) {
        latitude = r.center.latitude; longitude = r.center.longitude
        latitudeDelta = r.span.latitudeDelta; longitudeDelta = r.span.longitudeDelta
    }
}
struct SavedState: Codable {
    var fixes: [GPSPoint] = []
    var intervals: [AssignedInterval] = []
    var totals: [String: TimeInterval] = [:]
    var names: [String: String] = [:]
    var importedHashes: [String] = []
    var camera = CameraSave()
    var missingSeconds: TimeInterval = 0
}
@MainActor final class TimeModel: ObservableObject {
    @Published private(set) var data = SavedState()
    @Published var current: GPSPoint?
    @Published var currentVisitStart: Date?
    @Published var selected: Cell?
    @Published var gpsStatus = "Sin iniciar"
    @Published var recording = false
    @Published var explore = false
    @Published var obscured = false
    @Published var adaptive = false
    @Published var showRoutes = false
    @Published var mapKind: MKMapType = .standard
    @Published var minimized = false
    private var lastSaved = Date.distantPast
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("time-map-v1.json")
        if let blob = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(SavedState.self, from: blob) { data = saved }
    }
    var totalSeconds: TimeInterval { data.totals.values.reduce(0, +) }
    var allCells: [Cell] {
        data.totals.keys.compactMap {
            let a = $0.split(separator: ":")
            guard a.count == 2, let row = Int(a[0]), let col = Int(a[1]) else { return nil }
            return Cell(row: row, column: col)
        }
    }
    func total(for cell: Cell, now: Date = .now) -> TimeInterval {
        let base = data.totals[cell.id] ?? 0
        // The running value is provisional until the next GPS fix arrives.
        guard recording, let p = current, p.cell == cell else { return base }
        let age = now.timeIntervalSince(p.date)
        return base + (age >= 0 && age < 120 ? age : 0)
    }
    func staySeconds(now: Date = .now) -> TimeInterval {
        guard let start = currentVisitStart else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }
    func label(for cell: Cell) -> String { data.names[cell.id] ?? "Cuadrícula \(cell.id)" }
    func rename(_ cell: Cell, to name: String) {
        data.names[cell.id] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save(force: true)
    }
    func updateCamera(_ region: MKCoordinateRegion) {
        data.camera = CameraSave(region)
        save()
    }
    func record(_ location: CLLocation) {
        guard location.coordinate.latitude.isFinite,
              location.coordinate.longitude.isFinite,
              location.horizontalAccuracy >= 0 else { return }
        let sample = GPSPoint(date: location.timestamp, latitude: location.coordinate.latitude,
                              longitude: location.coordinate.longitude,
                              accuracy: location.horizontalAccuracy, source: "gps")
        if let last = data.fixes.last, sample.date <= last.date { return }
        if let last = data.fixes.last { attribute(from: last, to: sample) }
        data.fixes.append(sample)
        if current?.cell != sample.cell { currentVisitStart = sample.date }
        current = sample
        gpsStatus = "GPS activo · ±\(Int(sample.accuracy)) m"
        save()
        objectWillChange.send()
    }
    // Interpolate between real fixes. Long gaps / impossible jumps are NOT invented.
    private func attribute(from a: GPSPoint, to b: GPSPoint) {
        let dt = b.date.timeIntervalSince(a.date)
        guard dt > 0 else { return }
        let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        guard dt <= 180, a.accuracy <= 250, b.accuracy <= 250,
              distance <= dt * 380 + 1_000 else {
            data.missingSeconds += dt
            return
        }
        // For stationary positions, suppress minor GPS wobble.
        if distance <= min(35, max(a.accuracy, b.accuracy) * 1.4) {
            addInterval(start: a.date, end: b.date, cell: a.cell,
                        quality: "observado", source: a.source)
            return
        }
        let count = min(2_500, max(1, Int(ceil(max(distance / 20, dt / 1.5)))))
        var runCell: Cell?
        var runStart = a.date
        for i in 0..<count {
            let f = (Double(i) + 0.5) / Double(count)
            let cell = Grid.cell(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                 longitude: a.longitude + (b.longitude - a.longitude) * f)
            let boundary = a.date.addingTimeInterval(dt * Double(i) / Double(count))
            if cell != runCell {
                if let previous = runCell {
                    addInterval(start: runStart, end: boundary, cell: previous,
                                quality: "reconstruido", source: a.source)
                }
                runStart = boundary
                runCell = cell
            }
        }
        if let runCell {
            addInterval(start: runStart, end: b.date, cell: runCell,
                        quality: "reconstruido", source: a.source)
        }
    }
    private func addInterval(start: Date, end: Date, cell: Cell, quality: String, source: String) {
        guard end > start else { return }
        let segment = AssignedInterval(start: start, end: end, cell: cell, quality: quality, source: source)
        data.intervals.append(segment)
        data.totals[cell.id, default: 0] += segment.seconds
    }
    func importGPX(from url: URL) throws -> Int {
        let permitted = url.startAccessingSecurityScopedResource()
        defer { if permitted { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if data.importedHashes.contains(hash) { throw ImportFailure.duplicate }
        let parse = GPXReader()
        let points = try parse.read(bytes)
        guard !points.isEmpty else { throw ImportFailure.noTimes }
        data.importedHashes.append(hash)
        // Rebuild from the combined timeline to avoid double-adding old intervals.
        let combined = (data.fixes + points).sorted { $0.date < $1.date }
        var dedup: [GPSPoint] = []
        for point in combined {
            if let previous = dedup.last, abs(point.date.timeIntervalSince(previous.date)) < 1,
               point.cell == previous.cell { continue }
            dedup.append(point)
        }
        data.fixes = dedup
        data.intervals = []
        data.totals = [:]
        data.missingSeconds = 0
        for i in 1..<dedup.count { attribute(from: dedup[i - 1], to: dedup[i]) }
        save(force: true)
        objectWillChange.send()
        return points.count
    }
    func exportJSON() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mi-Mapa-del-Tiempo.json")
        try JSONEncoder().encode(data).write(to: url, options: .atomic)
        return url
    }
    func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        do {
            try JSONEncoder().encode(data).write(to: fileURL, options: .atomic)
            lastSaved = .now
        } catch {
            gpsStatus = "Error guardando datos: \(error.localizedDescription)"
        }
    }
}
enum ImportFailure: LocalizedError {
    case duplicate, noTimes
    var errorDescription: String? {
        switch self {
        case .duplicate: "Este archivo ya se importó."
        case .noTimes: "El archivo GPX no incluye puntos con fechas y coordenadas."
        }
    }
}
final class GPXReader: NSObject, XMLParserDelegate {
    private var parserPoints: [GPSPoint] = []
    private var inTrack = false
    private var readingTime = false
    private var timeText = ""
    private var lat = 0.0, lon = 0.0
    func read(_ bytes: Data) throws -> [GPSPoint] {
        parserPoints = []
        let parser = XMLParser(data: bytes)
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? ImportFailure.noTimes }
        return parserPoints.sorted { $0.date < $1.date }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let tag = elementName.components(separatedBy: ":").last ?? elementName
        if tag == "trkpt", let a = Double(attributes["lat"] ?? ""),
           let b = Double(attributes["lon"] ?? "") {
            inTrack = true; lat = a; lon = b
        } else if tag == "time" && inTrack { readingTime = true; timeText = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingTime { timeText += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.components(separatedBy: ":").last ?? elementName
        if tag == "time" && readingTime {
            readingTime = false
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = iso.date(from: timeText.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? ISO8601DateFormatter().date(from: timeText.trimmingCharacters(in: .whitespacesAndNewlines))
            if let date {
                parserPoints.append(GPSPoint(date: date, latitude: lat, longitude: lon,
                                             accuracy: 15, source: "gpx"))
            }
        }
        if tag == "trkpt" { inTrack = false }
    }
}
final class GPSService: NSObject, CLLocationManagerDelegate, ObservableObject {
    private let manager = CLLocationManager()
    weak var model: TimeModel?
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }
    @MainActor func begin(_ model: TimeModel) {
        self.model = model
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
        model.recording = true
        model.gpsStatus = "Esperando ubicación GPS"
    }
    @MainActor func end(_ model: TimeModel) {
        manager.stopUpdatingLocation()
        model.recording = false
        model.gpsStatus = "Detenido"
        model.save(force: true)
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
                model?.record(location)
            }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in model?.gpsStatus = "GPS: \(error.localizedDescription)" }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                model?.gpsStatus = "Permiso GPS denegado"
            }
        }
    }
}
@main struct MiMapaDelTiempoApp: App {
    @StateObject private var model = TimeModel()
    @StateObject private var gps = GPSService()
    var body: some Scene {
        WindowGroup {
            RootView(model: model, gps: gps)
                .onChange(of: model.recording) { _, isOn in if !isOn { model.save(force: true) } }
        }
    }
}
struct RootView: View {
    @ObservedObject var model: TimeModel
    @ObservedObject var gps: GPSService
    var body: some View {
        TabView {
            TimeMapView(model: model).tabItem { Label("Mapa", systemImage: "map") }
            TimeStatsView(model: model).tabItem { Label("Estadísticas", systemImage: "chart.bar") }
            TimeDiaryView(model: model).tabItem { Label("Histórico", systemImage: "clock.arrow.circlepath") }
            TimeSettingsView(model: model, gps: gps).tabItem { Label("Ajustes", systemImage: "gearshape") }
        }.tint(.teal)
    }
}
struct TimeMapView: View {
    @ObservedObject var model: TimeModel
    @State private var camera: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion = CameraSave().region
    @State private var rename = false
    @State private var newName = ""
    @State private var selectedSheet = false
    var relevant: [Cell] {
        model.allCells.filter { c in
            let point = Grid.center(c)
            return abs(point.latitude - region.center.latitude) < region.span.latitudeDelta * 1.1 &&
                   abs(point.longitude - region.center.longitude) < region.span.longitudeDelta * 1.1
        }.prefix(2_000).map { $0 }
    }
    func paint(_ sec: TimeInterval) -> Color {
        if model.explore { return .cyan }
        let d = sec / 86400
        if d > 365 { return Color(red: 0.59, green: 0.22, blue: 0.4) }
        if d > 30 { return .red }
        if d > 7 { return .orange }
        if d > 1 { return .yellow }
        if sec > 21_600 { return .green }
        if sec > 3600 { return .teal }
        return .cyan
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(relevant) { cell in
                        MapPolygon(coordinates: Grid.polygon(cell))
                            .foregroundStyle(paint(model.total(for: cell)).opacity(0.52))
                            .stroke(.white.opacity(0.85), lineWidth: 1)
                        if region.span.latitudeDelta < 0.015 {
                            Annotation("", coordinate: Grid.center(cell), anchor: .center) {
                                Text(DurationFormat.small(model.total(for: cell)))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(2)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    if let position = model.current {
                        Annotation("Actual", coordinate: position.coordinate) {
                            Circle().fill(.blue).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                    }
                    if model.showRoutes {
                        let recent = Array(model.data.fixes.suffix(800))
                        if recent.count > 1 {
                            MapPolyline(coordinates: recent.map(\.coordinate))
                                .stroke(.blue, lineWidth: 3)
                        }
                    }
                }
                .mapStyle(model.mapKind == .satellite ? .imagery : model.mapKind == .hybrid ? .hybrid : .standard)
                .onTapGesture { point in
                    if let coord = proxy.convert(point, from: .local) {
                        model.selected = Grid.cell(latitude: coord.latitude, longitude: coord.longitude)
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { ctx in
                    region = ctx.region
                    model.updateCamera(ctx.region)
                }
                .onAppear { camera = .region(model.data.camera.region); region = model.data.camera.region }
            }
            VStack {
                HStack {
                    Picker("Mapa", selection: $model.explore) {
                        Text("Permanencia").tag(false)
                        Text("Exploración").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 260)
                    Spacer()
                    Button {
                        if let fix = model.current {
                            camera = .region(MKCoordinateRegion(center: fix.coordinate,
                                span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004)))
                            model.selected = fix.cell
                        }
                    } label: {
                        Image(systemName: "location.fill").padding(11)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(12)
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.selected.map { model.label(for: $0) } ?? "Mi cuadrícula actual")
                            .font(.headline)
                        Spacer()
                        Button {
                            model.minimized.toggle()
                        } label: {
                            Image(systemName: model.minimized ? "chevron.up" : "chevron.down")
                        }.accessibilityLabel("Minimizar o expandir la tarjeta")
                    }
                    if !model.minimized {
                        let picked = model.selected ?? model.current?.cell
                        TimelineView(.periodic(from: .now, by: 1)) { tick in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(picked.map { DurationFormat.full(model.total(for: $0, now: tick.date)) }
                                     ?? DurationFormat.full(0))
                                    .font(.system(size: 21, weight: .bold, design: .rounded))
                                    .minimumScaleFactor(0.6)
                                    .lineLimit(1)
                                HStack {
                                    Text("Estancia actual")
                                    Spacer()
                                    Text(picked == model.current?.cell
                                         ? DurationFormat.full(model.staySeconds(now: tick.date)) : "—")
                                }.font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Label(model.gpsStatus, systemImage: "location.circle").font(.caption2)
                            Spacer()
                            if model.selected != nil {
                                Button("Nombre") {
                                    newName = model.selected.map { model.label(for: $0) } ?? ""
                                    rename = true
                                }.font(.caption)
                            }
                        }.foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(12)
            }
        }
        .alert("Nombrar cuadrícula", isPresented: $rename) {
            TextField("Nombre", text: $newName)
            Button("Guardar") {
                if let selected = model.selected { model.rename(selected, to: newName) }
            }
            Button("Cancelar", role: .cancel) {}
        }
    }
}
struct TimeStatsView: View {
    @ObservedObject var model: TimeModel
    var body: some View {
        NavigationStack {
            List {
                Section("Resumen acumulado") {
                    LabeledContent("Tiempo asignado", value: DurationFormat.full(model.totalSeconds))
                    LabeledContent("Cuadrículas visitadas", value: "\(model.allCells.count)")
                    LabeledContent("Superficie aproximada", value: String(format: "%.2f km²", Double(model.allCells.count) * 0.01))
                    LabeledContent("Tiempo sin ubicación fiable", value: DurationFormat.full(model.data.missingSeconds))
                }
                Section("Cuadrículas con más tiempo") {
                    ForEach(model.allCells.sorted {
                        (model.data.totals[$0.id] ?? 0) > (model.data.totals[$1.id] ?? 0)
                    }.prefix(30)) { cell in
                        LabeledContent(model.label(for: cell),
                                       value: DurationFormat.full(model.data.totals[cell.id] ?? 0))
                    }
                }
            }
            .navigationTitle("Estadísticas")
        }
    }
}
struct TimeDiaryView: View {
    @ObservedObject var model: TimeModel
    private var dates: [(String, [GPSPoint])] {
        // Prototype: device-local dates. Place-specific time-zone identification is planned.
        let grouped = Dictionary(grouping: model.data.fixes) {
            DateFormatter.localizedString(from: $0.date, dateStyle: .medium, timeStyle: .none)
        }
        return grouped.map { ($0.key, $0.value) }
            .sorted { ($0.1.last?.date ?? .distantPast) > ($1.1.last?.date ?? .distantPast) }
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(dates, id: \.0) { day, points in
                    NavigationLink {
                        List(points) { point in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(point.date, style: .time)
                                Text("\(point.latitude, specifier: "%.5f"), \(point.longitude, specifier: "%.5f")")
                                    .font(.caption.monospaced())
                                Text("±\(point.accuracy, specifier: "%.0f") m · \(point.source)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.navigationTitle(day)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(day)
                            Text("\(points.count) posiciones GPS")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Histórico")
        }
    }
}
struct TimeSettingsView: View {
    @ObservedObject var model: TimeModel
    @ObservedObject var gps: GPSService
    @State private var importing = false
    @State private var message = ""
    @State private var exportFile: URL?
    var body: some View {
        NavigationStack {
            Form {
                Section("Seguimiento") {
                    LabeledContent("Estado", value: model.gpsStatus)
                    Button(model.recording ? "Detener GPS" : "Iniciar GPS de máxima precisión") {
                        if model.recording { gps.end(model) } else { gps.begin(model) }
                    }
                }
                Section("Mapa") {
                    Toggle("Mostrar recorridos recientes", isOn: $model.showRoutes)
                    Toggle("Territorio por descubrir", isOn: $model.obscured)
                    Toggle("Escala de colores adaptada", isOn: $model.adaptive)
                }
                Section("Datos") {
                    Button("Importar archivo GPX") { importing = true }
                    Button("Preparar exportación JSON") {
                        do { exportFile = try model.exportJSON() }
                        catch { message = error.localizedDescription }
                    }
                    if let exportFile { ShareLink(item: exportFile) { Label("Compartir copia JSON", systemImage: "square.and.arrow.up") } }
                    if !message.isEmpty { Text(message).font(.footnote) }
                }
                Section("Limitaciones actuales") {
                    Text("Versión inicial: requiere probar permisos y segundo plano en un iPhone real. No incluye todavía copia cifrada propia en iCloud, Face ID, widgets, geometrías libres, análisis de lugares, comparaciones ni reproducción animada completa.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Ajustes")
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { result in
                do {
                    let url = try result.get()
                    let count = try model.importGPX(from: url)
                    message = "Importadas \(count) posiciones GPS."
                } catch { message = error.localizedDescription }
            }
        }
    }
}