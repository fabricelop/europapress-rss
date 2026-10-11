import SwiftUI
import MapKit
import CoreLocation
import CoreMotion
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
        var parts: [String] = []
        if months > 0 { parts.append("\(months) \(months == 1 ? "mes" : "meses")") }
        if days > 0 { parts.append("\(days) d") }
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if n > 0 || parts.isEmpty { parts.append("\(n) s") }
        return parts.joined(separator:" ")
    }
    static func small(_ seconds: TimeInterval) -> String {
        var n = Int(max(0, seconds))
        let months = n / 2_592_000; n %= 2_592_000
        let days = n / 86_400; n %= 86_400
        let hours = n / 3_600; n %= 3_600
        let minutes = n / 60; n %= 60
        let parts = [
            months > 0 ? "\(months)mes" : "",
            days > 0 ? "\(days)d" : "",
            hours > 0 ? "\(hours)h" : "",
            minutes > 0 ? "\(minutes)m" : "",
            n > 0 ? "\(n)s" : ""
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? "0s" : parts.prefix(2).joined(separator:" ")
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
    var savedVisitStart: Date?
    var manualBreaks: [Date] = []
    // Persiste la intención de grabar para reanudar el seguimiento al abrir la app.
    var trackingEnabled = false

    init() {}
    // El JSON v1 carece de manualBreaks y de otras propiedades posteriores.
    // No hacer que una propiedad nueva inutilice una copia histórica antigua.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy:CodingKeys.self)
        fixes = try box.decodeIfPresent([GPSPoint].self,forKey:.fixes) ?? []
        intervals = try box.decodeIfPresent([AssignedInterval].self,forKey:.intervals) ?? []
        totals = try box.decodeIfPresent([String:TimeInterval].self,forKey:.totals) ?? [:]
        names = try box.decodeIfPresent([String:String].self,forKey:.names) ?? [:]
        importedHashes = try box.decodeIfPresent([String].self,forKey:.importedHashes) ?? []
        camera = try box.decodeIfPresent(CameraSave.self,forKey:.camera) ?? CameraSave()
        missingSeconds = try box.decodeIfPresent(TimeInterval.self,forKey:.missingSeconds) ?? 0
        savedVisitStart = try box.decodeIfPresent(Date.self,forKey:.savedVisitStart)
        trackingEnabled = try box.decodeIfPresent(Bool.self,forKey:.trackingEnabled) ?? false
        manualBreaks = try box.decodeIfPresent([Date].self,forKey:.manualBreaks) ?? []
    }
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
    @Published var period: TimePeriod = .all
    @Published var mapKind: MKMapType = .standard
    @Published var minimized = false
    @Published var forceBasicMap = false
    @Published private(set) var storeStatus = "Cargando"
    private var lastSaved = Date.distantPast
    private let widgetPublisher = TimeWidgetPublisher()
    private let fileURL: URL
    private var store: TimeSQLiteStore?
    private var lastProcessedSample: GPSPoint?
    private var pendingFixes: [GPSPoint] = []
    private var pendingIntervals: [AssignedInterval] = []
    private var pendingTotals: [String: TimeInterval] = [:]
    private var stableCell: Cell?
    private var candidateCell: Cell?
    private var candidateSince: Date?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("time-map-v1.json")
        let legacy: SavedState? = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        do {
            let db = try TimeSQLiteStore(url: dir.appendingPathComponent("time-map-v3.sqlite"))
            if !db.hasExistingState { try db.replaceAll(legacy ?? SavedState()) }
            data = try db.load()
            store = db
            storeStatus = "SQLite · protegido localmente"
        } catch {
            // Si falla una migración, los datos anteriores siguen en el JSON original.
            data = legacy ?? SavedState()
            storeStatus = "JSON de respaldo · revisar SQLite: \(error.localizedDescription)"
        }
        currentVisitStart = data.savedVisitStart
        stableCell = data.fixes.last?.cell
        lastProcessedSample = data.fixes.last
        widgetPublisher.publish(from:self,force:true)
    }
    var totalSeconds: TimeInterval { data.totals.values.reduce(0, +) }
    var allCells: [Cell] {
        data.totals.keys.compactMap {
            let a = $0.split(separator: ":")
            guard a.count == 2, let row = Int(a[0]), let col = Int(a[1]) else { return nil }
            return Cell(row: row, column: col)
        }
    }
    func periodTotals(now: Date = .now) -> [String:TimeInterval] {
        guard let window = TimeAnalytics.window(for: period, now: now) else { return data.totals }
        return TimeAnalytics.totals(data.intervals, from:window.start, to:window.end)
    }
    func total(for cell: Cell, now: Date = .now) -> TimeInterval {
        let base = period == .all ? (data.totals[cell.id] ?? 0) : (periodTotals(now: now)[cell.id] ?? 0)
        // Solo contar provisionalmente si la muestra actual sigue siendo reciente.
        guard recording, let p = current, p.cell == cell else { return base }
        let age = now.timeIntervalSince(p.date)
        guard age >= 0 && age < 120 else { return base }
        if let window = TimeAnalytics.window(for: period, now: now) {
            return base + max(0, now.timeIntervalSince(max(window.start,p.date)))
        }
        return base + age
    }
    func staySeconds(now: Date = .now) -> TimeInterval {
        guard recording, current != nil, let start = currentVisitStart else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }
    var activeCell: Cell? { stableCell ?? current?.cell }
    var retainedFixCount: Int { data.fixes.count }
    var lastGPSFix: Date? { lastProcessedSample?.date ?? data.fixes.last?.date }
    var lastAccuracy: Double? { current?.accuracy }
    func splitEpisode(at date: Date) {
        guard !data.manualBreaks.contains(where: { abs($0.timeIntervalSince(date)) < 1 }) else { return }
        data.manualBreaks.append(date)
        data.manualBreaks.sort()
        save(force: true)
        objectWillChange.send()
    }
    func removeSplit(at date: Date) {
        data.manualBreaks.removeAll { abs($0.timeIntervalSince(date)) < 1 }
        save(force: true)
        objectWillChange.send()
    }
    func label(for cell: Cell) -> String { data.names[cell.id] ?? "Cuadrícula \(cell.id)" }
    func rename(_ cell: Cell, to name: String) {
        data.names[cell.id] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save(force: true)
        widgetPublisher.publish(from:self,force:true)
    }
    func setTrackingEnabled(_ enabled: Bool) {
        data.trackingEnabled = enabled
        save(force: true)
        widgetPublisher.publish(from:self,force:true)
    }
    func updateCamera(_ region: MKCoordinateRegion) {
        data.camera = CameraSave(region)
        save()
    }
    func record(_ location: CLLocation) {
        guard location.coordinate.latitude.isFinite,
              location.coordinate.longitude.isFinite,
              location.horizontalAccuracy >= 0,
              location.timestamp <= Date().addingTimeInterval(5) else { return }
        let sample = GPSPoint(date: location.timestamp, latitude: location.coordinate.latitude,
                              longitude: location.coordinate.longitude,
                              accuracy: location.horizontalAccuracy, source: "gps")
        let previous = lastProcessedSample
        if let previous, sample.date <= previous.date { return }
        let distance = previous.map { a in
            CLLocation(latitude:a.latitude, longitude:a.longitude)
                .distance(from:location)
        } ?? 0
        let delta = previous.map { sample.date.timeIntervalSince($0.date) } ?? .infinity

        // Histeresis para cambios de cuadrícula causados por oscilaciones del GPS.
        let target = sample.cell
        let beforeStable = stableCell
        if stableCell == nil { stableCell = target }
        if target == stableCell {
            candidateCell = nil
            candidateSince = nil
        } else if distance > max(18, min(45, sample.accuracy * 1.8)) {
            stableCell = target
            candidateCell = nil
            candidateSince = nil
        } else {
            if candidateCell != target { candidateCell = target; candidateSince = sample.date }
            if let since = candidateSince, sample.date.timeIntervalSince(since) >= 10,
               sample.accuracy <= 35 {
                stableCell = target
                candidateCell = nil
                candidateSince = nil
            }
        }
        if let previous { attribute(from:previous,to:sample) }
        lastProcessedSample = sample
        // Conservar muestras representativas, no miles de coordenadas repetidas
        // cuando las muestras intermedias solo confirman inmovilidad.
        let lastRetained = data.fixes.last
        let retainedDistance = lastRetained.map { old in
            CLLocation(latitude:old.latitude, longitude:old.longitude)
                .distance(from:location)
        } ?? .infinity
        let retainedAge = lastRetained.map { sample.date.timeIntervalSince($0.date) } ?? .infinity
        if retainedAge >= 90 || retainedDistance >= 12 || lastRetained?.cell != sample.cell {
            data.fixes.append(sample)
            pendingFixes.append(sample)
        }
        if stableCell != beforeStable ||
           delta > GPSHistoryGrouping.gapLimit || currentVisitStart == nil {
            currentVisitStart = sample.date
            data.savedVisitStart = sample.date
        }
        current = sample
        gpsStatus = "GPS activo · ±\(Int(sample.accuracy)) m"
        save(force: delta > GPSHistoryGrouping.gapLimit)
        widgetPublisher.publish(from:self)
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
            addInterval(start: a.date, end: b.date, cell: stableCell ?? a.cell,
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
        if let last = pendingIntervals.last, let existing = data.intervals.last,
           last.id == existing.id && last.cell == cell && last.quality == quality &&
           last.source == source && abs(last.end.timeIntervalSince(start)) < 0.05 {
            let replacement = AssignedInterval(id: last.id, start:last.start, end:end,
                                               cell:cell, quality:quality, source:source)
            pendingIntervals[pendingIntervals.count - 1] = replacement
            data.intervals[data.intervals.count - 1] = replacement
        } else {
            let segment = AssignedInterval(start:start, end:end, cell:cell,
                                           quality:quality, source:source)
            data.intervals.append(segment)
            pendingIntervals.append(segment)
        }
        let delta = end.timeIntervalSince(start)
        data.totals[cell.id, default:0] += delta
        pendingTotals[cell.id, default:0] += delta
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
        let previousSnapshot = data
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
        currentVisitStart = nil
        data.savedVisitStart = nil
        data.intervals = []
        data.totals = [:]
        data.missingSeconds = 0
        let oldPendingFixes = pendingFixes
        let oldPendingIntervals = pendingIntervals
        let oldPendingTotals = pendingTotals
        pendingFixes = []
        pendingIntervals = []
        pendingTotals = [:]
        for i in 1..<dedup.count { attribute(from:dedup[i-1], to:dedup[i]) }
        do {
            try store?.replaceAll(data)
            pendingFixes = []
            pendingIntervals = []
            pendingTotals = [:]
            lastProcessedSample = data.fixes.last
            stableCell = data.fixes.last?.cell
            save(force:true)
            widgetPublisher.publish(from:self,force:true)
            objectWillChange.send()
            return points.count
        } catch {
            data = previousSnapshot
            pendingFixes = oldPendingFixes
            pendingIntervals = oldPendingIntervals
            pendingTotals = oldPendingTotals
            throw error
        }
    }
    func exportJSON() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mi-Mapa-del-Tiempo.json")
        try JSONEncoder().encode(data).write(to: url, options: .atomic)
        return url
    }
    func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSaved) > 20 else { return }
        do {
            if let store {
                try store.append(fixes:pendingFixes, intervals:pendingIntervals,
                                 totals:pendingTotals, header:TimeStoreHeader(data))
                pendingFixes.removeAll(keepingCapacity:true)
                pendingIntervals.removeAll(keepingCapacity:true)
                pendingTotals.removeAll(keepingCapacity:true)
            } else {
                try JSONEncoder().encode(data).write(to:fileURL,options:.atomic)
            }
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
    private let motion = MotionObserver()
    private var decision = SmartGPSDecision()
    private var motionMoving: Bool?
    private var lastPosition: CLLocation?
    private var lastMotionChange: Date = .distantPast
    weak var model: TimeModel?

    @Published private(set) var mode: GPSPowerMode = .precision
    @Published private(set) var movingSoon = false
    @Published private(set) var motionAvailable = CMMotionActivityManager.isActivityAvailable()

    override init() {
        super.init()
        manager.delegate = self
        configure(.precision)
    }
    private func configure(_ target: GPSPowerMode) {
        guard mode != target || manager.desiredAccuracy != (target == .precision ?
                    kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyNearestTenMeters)
        else { return }
        mode = target
        if target == .precision {
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
            manager.activityType = .otherNavigation
            manager.pausesLocationUpdatesAutomatically = false
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 20
            manager.activityType = .other
            manager.pausesLocationUpdatesAutomatically = true
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }
    @MainActor func begin(_ model: TimeModel) {
        self.model = model
        manager.requestAlwaysAuthorization()
        configure(.precision)
        manager.startUpdatingLocation()
        if manager.authorizationStatus == .authorizedAlways {
            manager.startMonitoringSignificantLocationChanges()
        }
        motion.begin { [weak self] moving in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.motionMoving = moving
                if moving == true {
                    self.decision.motionStarted(at:Date())
                    self.applyMode()
                }
            }
        }
        model.recording = true
        model.setTrackingEnabled(true)
        model.gpsStatus = "GPS inteligente · buscando ubicación"
    }
    @MainActor func end(_ model: TimeModel) {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        motion.end()
        model.recording = false
        model.setTrackingEnabled(false)
        model.gpsStatus = "Detenido"
        model.save(force:true)
        movingSoon = false
        decision = SmartGPSDecision()
        mode = .precision
    }
    @MainActor func setAnticipation(_ enabled: Bool) {
        if enabled { decision.anticipate() }
        else { decision.cancelAnticipation() }
        movingSoon = decision.movingSoon
        applyMode()
    }
    @MainActor private func applyMode() {
        movingSoon = decision.movingSoon
        if mode != decision.mode {
            configure(decision.mode)
            // La modificación del filtro entra en vigor sin reiniciar la sesión GPS.
        }
    }
    @MainActor private func observe(_ location: CLLocation) {
        let distance = lastPosition.map { $0.distance(from:location) } ?? 0
        lastPosition = location
        decision.observe(date:location.timestamp,
                         speed: max(0,location.speed),
                         metersSincePrevious:distance,
                         motionMoving:motionMoving)
        applyMode()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
                model?.record(location)
                observe(location)
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
            } else if manager.authorizationStatus == .authorizedAlways, model?.recording == true {
                manager.startMonitoringSignificantLocationChanges()
            }
        }
    }
}
@main struct MiMapaDelTiempoApp: App {
    @StateObject private var model = TimeModel()
    @StateObject private var gps = GPSService()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView(model: model, gps: gps)
                .environment(\.locale, Locale(identifier:"es_ES"))
                .onAppear {
                    // Se reactiva al volver a abrir la app, respetando la opción previa.
                    if model.data.trackingEnabled && !model.recording { gps.begin(model) }
                }
                .onChange(of: phase) { _, state in
                    if state != .active { model.save(force: true) }
                }
        }
    }
}
struct RootView: View {
    @ObservedObject var model: TimeModel
    @ObservedObject var gps: GPSService
    @AppStorage("miMapaFaceID") private var faceIDEnabled = false
    @Environment(\.scenePhase) private var phase
    @State private var unlocked = false
    @State private var checking = false
    var body: some View {
        ZStack {
            TabView {
                TimeMapView(model: model, gps: gps).tabItem { Label("Mapa", systemImage: "map") }
                TimeStatsDashboard(model: model).tabItem { Label("Estadísticas", systemImage: "chart.bar.fill") }
                GPSDiaryShell(model: model).tabItem { Label("Histórico", systemImage: "clock.arrow.circlepath") }
                TimeCompareView(model: model).tabItem { Label("Comparar", systemImage: "square.split.2x1") }
                TimeSettingsView(model: model, gps: gps).tabItem { Label("Ajustes", systemImage: "gearshape") }
            }.tint(.teal)
            if faceIDEnabled && !unlocked {
                VStack(spacing:20) {
                    Image(systemName:"lock.shield.fill").font(.system(size:54)).foregroundStyle(.teal)
                    Text("Mi Mapa del Tiempo").font(.title2.bold())
                    Text("El seguimiento GPS continúa aunque la pantalla esté protegida.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button {
                        checkFaceID()
                    } label: {
                        Label(checking ? "Verificando…" : "Desbloquear",systemImage:"faceid")
                    }.buttonStyle(.borderedProminent).disabled(checking)
                }
                .padding(28)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .background(Color(.systemBackground).ignoresSafeArea())
            }
        }
        .onAppear { unlocked = !faceIDEnabled; if faceIDEnabled { checkFaceID() } }
        .onChange(of:faceIDEnabled) { _, enabled in
            unlocked = !enabled
            if enabled { checkFaceID() }
        }
        .onChange(of:phase) { _, state in
            if faceIDEnabled {
                if state == .background { unlocked = false }
                if state == .active && !unlocked { checkFaceID() }
            }
        }
    }
    private func checkFaceID() {
        guard faceIDEnabled, !checking else { return }
        checking = true
        DeviceAccess.authenticate { approved in
            checking = false
            unlocked = approved
        }
    }
}
struct TimeMapView: View {
    @ObservedObject var model: TimeModel
    @ObservedObject var gps: GPSService
    @StateObject private var connectivity = MapConnectivity()
    @State private var camera: MapCameraPosition = .automatic
    @State private var region: MKCoordinateRegion = CameraSave().region
    @State private var rename = false
    @State private var newName = ""
    @State private var selectedSheet = false
    var relevant: [Cell] {
        model.allCells.filter { c in
            guard model.total(for: c) > 0 else { return false }
            let point = Grid.center(c)
            return abs(point.latitude - region.center.latitude) < region.span.latitudeDelta * 1.1 &&
                   abs(point.longitude - region.center.longitude) < region.span.longitudeDelta * 1.1
        }.prefix(2_000).map { $0 }
    }
    func paint(_ sec: TimeInterval) -> Color {
        if model.explore { return .cyan }
        if model.adaptive {
            let maximum = max(1, relevant.map { model.total(for:$0) }.max() ?? 1)
            let t = min(1, max(0, log1p(sec) / log1p(maximum)))
            return Color(hue:0.58 - 0.56*t, saturation:0.76, brightness:0.93)
        }
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
            if model.forceBasicMap || !connectivity.connected {
                OfflineGridMap(model:model,region:$region) { newRegion in
                    model.updateCamera(newRegion)
                    camera = .region(newRegion)
                }
                .onAppear { region = model.data.camera.region }
            } else {
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
                        let groups = GPSRouteSegments.split(recent.map {
                            GPSHistoryFix(date: $0.date, latitude: $0.latitude, longitude: $0.longitude)
                        })
                        ForEach(groups.indices, id: \.self) { index in
                            MapPolyline(coordinates: groups[index].map {
                                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                            })
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
            }
            VStack {
                HStack {
                    Menu {
                        Button { model.explore = false } label: {
                            Label("Permanencia · tiempo acumulado", systemImage:"hourglass")
                        }
                        Button { model.explore = true } label: {
                            Label("Exploración · zonas descubiertas", systemImage:"figure.walk")
                        }
                    } label: {
                        Label(model.explore ? "Exploración" : "Permanencia",
                              systemImage:model.explore ? "figure.walk" : "hourglass")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal,12).padding(.vertical,9)
                            .background(.regularMaterial,in:Capsule())
                    }
                    Spacer()
                    Button {
                        if let fix = model.current {
                            let target = MKCoordinateRegion(center: fix.coordinate,
                                span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004))
                            camera = .region(target)
                            region = target
                            model.updateCamera(target)
                            model.selected = model.activeCell
                        }
                    } label: {
                        Image(systemName: "location.fill").padding(11)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(12)
                if model.recording {
                    HStack {
                        Button {
                            gps.setAnticipation(!gps.movingSoon)
                        } label: {
                            Label(gps.movingSoon ? "Movimiento anticipado" : "Voy a moverme",
                                  systemImage:gps.movingSoon ? "location.north.fill" : "figure.walk")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal,12).padding(.vertical,7)
                                .foregroundStyle(gps.movingSoon ? Color.white : Color.primary)
                                .background(gps.movingSoon ? Color.teal : Color(.secondarySystemBackground),
                                            in:Capsule())
                        }
                        Spacer()
                        Text(gps.mode.rawValue)
                            .font(.caption2).padding(.horizontal,9).padding(.vertical,6)
                            .background(.regularMaterial,in:Capsule())
                    }.padding(.horizontal,12)
                }
                HStack(spacing:4) {
                    ForEach(TimePeriod.allCases) { p in
                        Button(p.title) { model.period = p }
                            .font(.caption2.weight(model.period == p ? .bold : .medium))
                            .padding(.horizontal,9).padding(.vertical,7)
                            .background(model.period == p ? Color.teal.opacity(0.86) :
                                        Color(.secondarySystemBackground).opacity(0.92),in:Capsule())
                            .foregroundStyle(model.period == p ? Color.white : Color.primary)
                    }
                    Spacer(minLength:0)
                }.padding(.horizontal,12)
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.selected.map { model.label(for:$0) } ??
                             (model.activeCell.map { model.label(for:$0) } ?? "Mi cuadrícula actual"))
                            .font(.headline)
                        Spacer()
                        Button {
                            model.minimized.toggle()
                        } label: {
                            Image(systemName: model.minimized ? "chevron.up" : "chevron.down")
                        }.accessibilityLabel("Minimizar o expandir la tarjeta")
                    }
                    if !model.minimized {
                        let picked = model.selected ?? model.activeCell
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
                                    Text(picked == model.activeCell
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
    @AppStorage("miMapaFaceID") private var faceIDEnabled = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Seguimiento") {
                    LabeledContent("Estado", value: model.gpsStatus)
                    Text("Tras activarlo una vez, el seguimiento se reanuda automáticamente al abrir la aplicación. iOS puede limitar o interrumpir la localización en segundo plano.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Modo GPS",value:gps.mode.rawValue)
                    Toggle("Voy a moverme",isOn:Binding(get:{gps.movingSoon},
                        set:{gps.setAnticipation($0)}))
                        .disabled(!model.recording)
                    Text("Anticipa máxima precisión. Se desactiva automáticamente tras 10 minutos de reposo confirmado; aunque lo olvides, el móvil intenta detectar movimiento por sí solo.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.recording ? "Detener GPS" : "Iniciar GPS inteligente") {
                        if model.recording { gps.end(model) } else { gps.begin(model) }
                    }
                }
                Section("Privacidad") {
                    Toggle("Solicitar Face ID o código", isOn:$faceIDEnabled)
                    Text("Solo bloquea el acceso a la pantalla. El GPS continúa registrando en segundo plano cuando iOS lo permita.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Mapa") {
                    Toggle("Mostrar recorridos recientes", isOn: $model.showRoutes)
                    Toggle("Usar mapa básico (sin calles)", isOn:$model.forceBasicMap)
                    Text("Se activa automáticamente si no hay Internet; el mapa básico funciona sin descargar cartografía.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Territorio por descubrir", isOn: $model.obscured)
                        .disabled(true)
                    Text("Sombrear las áreas no visitadas sigue pendiente. Este interruptor se activará cuando esté implementado.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Escala de colores adaptada", isOn: $model.adaptive)
                    Text("Permanencia: tiempo en cada cuadrícula. Exploración: territorio visitado. La escala adaptada destaca las diferencias en la zona visible.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Widgets iPhone") {
                    LabeledContent("Datos compartidos",
                        value: TimeWidgetStorage.isAvailable ? "App Group disponible" : "App Group no autorizado")
                    Text("En la pantalla de inicio: mantén pulsado un espacio libre, toca Editar → Añadir widget y busca Mi Mapa del Tiempo. En la pantalla bloqueada: mantén pulsado, Personalizar y selecciona Widgets.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Muestran tiempo histórico confirmado y última estancia conocida. No se actualizan cada segundo; iOS regula sus recargas. La firma gratuita puede impedir el App Group y entonces el widget aparecerá sin datos.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Diagnóstico") {
                    NavigationLink("Estado técnico del GPS y almacenamiento") {
                        GPSDiagnosticsView(model:model,gps:gps)
                    }
                    Text("Las posiciones técnicas se consultan aquí, no en Estadísticas.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Datos") {
                    Button("Importar archivo GPX") { importing = true }
                    Text("Importar GPX añade recorridos antiguos con hora. Exportar JSON crea una copia de seguridad manual; conviene conservarla fuera del iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Preparar exportación JSON") {
                        do { exportFile = try model.exportJSON() }
                        catch { message = error.localizedDescription }
                    }
                    if let exportFile { ShareLink(item: exportFile) { Label("Compartir copia JSON", systemImage: "square.and.arrow.up") } }
                    if !message.isEmpty { Text(message).font(.footnote) }
                }
                Section("Limitaciones actuales") {
                    Text("GPS inteligente y base SQLite experimental: comprobar la batería y el segundo plano en iPhone. Aún faltan widgets, copia cifrada iCloud, zonas libres y estadísticas por ciudad.")
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