import SwiftUI
import Combine
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
    var places: [UserPlace] = []
    var territoryCache: [String:TerritoryRecord] = [:]
    var powerEvents: [GPSPowerEvent] = []
    var shortIDs: [String:Int] = [:]
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
        places = try box.decodeIfPresent([UserPlace].self,forKey:.places) ?? []
        territoryCache = try box.decodeIfPresent([String:TerritoryRecord].self,forKey:.territoryCache) ?? [:]
        powerEvents = try box.decodeIfPresent([GPSPowerEvent].self,forKey:.powerEvents) ?? []
        shortIDs = try box.decodeIfPresent([String:Int].self,forKey:.shortIDs) ?? [:]
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
    @Published var adaptive = true
    @Published var showRoutes = true
    @Published var period: TimePeriod = .all
    @Published var mapKind: MKMapType = .standard
    @Published var minimized = false
    @Published var routePeriod: RouteDisplayPeriod = .today
    @Published var selectedTab = 0
    @Published var targetMapCell: Cell?
    @Published var mapNavigationRevision = UUID()
    @Published private(set) var renameUndoAvailable = false
    private var renameUndoSnapshot: (names:[String:String],places:[UserPlace])?
    var savedPowerEvents: [GPSPowerEvent] { data.powerEvents }
    func recordPowerEvent(mode:GPSPowerMode,cause:String) {
        data.powerEvents.append(GPSPowerEvent(date:Date(),mode:mode.rawValue,cause:cause))
        if data.powerEvents.count > 500 {
            data.powerEvents.removeFirst(data.powerEvents.count-500)
        }
        save(force:true)
    }
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
    // Vista canónica cacheada: evita recalcular miles de intervalos en cada repintado.
    private var normalizedTotalsCache: [String:TimeInterval] = [:]
    private var normalizedCacheIntervalCount = -1
    private var normalizedCacheLastEnd: Date?
    private var normalizedCacheTime: Date = .distantPast

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
        let previousNames = data.names
        let previousPlaces = data.places
        let integrityBefore = (data.fixes.count,data.intervals.count,data.totals)
        var migratedNames=data.names
        var migratedPlaces=data.places
        NamedPlaces.migrate(names:&migratedNames,places:&migratedPlaces)
        // La migración de nombres nunca tiene permiso para alterar los intervalos.
        if data.fixes.count == integrityBefore.0 &&
           data.intervals.count == integrityBefore.1 &&
           data.totals == integrityBefore.2 {
            data.names=migratedNames
            data.places=migratedPlaces
        } else {
            storeStatus="Datos antiguos conservados; revisar migración de nombres"
        }
        if data.names != previousNames || data.places != previousPlaces {
            save(force:true)
        }
        if data.shortIDs.isEmpty && !data.intervals.isEmpty {
            for interval in data.intervals.sorted(by:{$0.start < $1.start}) {
                assignShortID(interval.cell.id)
            }
            for id in data.totals.keys.sorted() { assignShortID(id) }
            save(force:true)
        }
        adaptive = UserDefaults.standard.object(forKey:"mapAdaptiveV5") as? Bool ?? true
        showRoutes = UserDefaults.standard.object(forKey:"mapRoutesV5") as? Bool ?? true
        routePeriod = RouteDisplayPeriod(rawValue:UserDefaults.standard.string(forKey:"mapRoutePeriodV5") ?? "") ?? .today
        widgetPublisher.publish(from:self,force:true)
    }
    var totalSeconds: TimeInterval { confirmedTotals().values.reduce(0, +) }
    var allCells: [Cell] {
        data.totals.keys.compactMap {
            let a = $0.split(separator: ":")
            guard a.count == 2, let row = Int(a[0]), let col = Int(a[1]) else { return nil }
            return Cell(row: row, column: col)
        }
    }
    func confirmedTotals(now:Date = .now) -> [String:TimeInterval] {
        let changed = data.intervals.count != normalizedCacheIntervalCount ||
                      data.intervals.last?.end != normalizedCacheLastEnd
        if normalizedCacheIntervalCount < 0 ||
           changed && now.timeIntervalSince(normalizedCacheTime) >= 5 {
            normalizedTotalsCache=TimeAttribution.byCell(data.intervals)
            normalizedCacheIntervalCount=data.intervals.count
            normalizedCacheLastEnd=data.intervals.last?.end
            normalizedCacheTime=now
        }
        return normalizedTotalsCache
    }
    func periodTotals(now: Date = .now) -> [String:TimeInterval] {
        guard let window = TimeAnalytics.window(for:period,now:now) else {
            return confirmedTotals(now:now)
        }
        return TimeAttribution.byCell(data.intervals,window:window)
    }
    func confirmed(for cell:Cell,now:Date = .now) -> TimeInterval {
        periodTotals(now:now)[cell.id] ?? 0
    }
    // La estimación se muestra separada: nunca se persiste ni se atribuye
    // a intervalos GPS hasta comprobar una nueva posición.
    func provisionalSeconds(for cellIDs:Set<String>,now:Date = .now) -> TimeInterval {
        guard recording,let fix=current,
              let stable=activeCell,cellIDs.contains(stable.id),
              fix.date <= now else { return 0 }
        let age=now.timeIntervalSince(fix.date)
        guard age>=0,age<=120 else { return 0 }
        let currentStart=max(fix.date,
                             TimeAnalytics.window(for:period,now:now)?.start ?? .distantPast)
        return max(0,now.timeIntervalSince(currentStart))
    }
    func gpsFixAge(now:Date = .now) -> TimeInterval? {
        guard let date=lastGPSFix else { return nil }
        return max(0,now.timeIntervalSince(date))
    }
    func total(for cell:Cell,now:Date = .now) -> TimeInterval {
        confirmed(for:cell,now:now)+provisionalSeconds(for:[cell.id],now:now)
    }
    func total(for place:UserPlace,now:Date = .now) -> TimeInterval {
        let totals=periodTotals(now:now)
        return place.normalizedCellIDs.reduce(0){$0+(totals[$1] ?? 0)}
             + provisionalSeconds(for:place.normalizedCellIDs,now:now)
    }
    func staySeconds(now: Date = .now) -> TimeInterval {
        guard recording, current != nil, let start = currentVisitStart,
              let lastFix=lastGPSFix else { return 0 }
        // Si iOS deja de proporcionar posiciones no se puede afirmar
        // que la estancia siga en la misma casilla indefinidamente.
        let provisionalEnd=min(now,lastFix.addingTimeInterval(120))
        return max(0, provisionalEnd.timeIntervalSince(start))
    }
    var activeCell: Cell? { stableCell ?? current?.cell }
    func refreshWidgets() {
        widgetPublisher.publish(from:self,force:true)
    }
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
    func label(for cell:Cell) -> String {
        FriendlyCellName.title(cell,index:data.shortIDs[cell.id],custom:data.names[cell.id])
    }
    private func assignShortID(_ id:String) {
        guard data.shortIDs[id] == nil else { return }
        data.shortIDs[id] = (data.shortIDs.values.max() ?? 0)+1
    }
    func hasCustomName(_ id: String) -> Bool {
        !(data.names[id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    func navigate(to cell: Cell) {
        selected = cell
        targetMapCell = cell
        mapNavigationRevision=UUID() // permite navegar dos veces a la misma zona
        selectedTab = 0
    }
    func proposalForRename(_ cell:Cell, to rawName:String) -> NameProposal {
        let title=rawName.trimmingCharacters(in:.whitespacesAndNewlines)
        let excluding = data.places.filter { !$0.cellIDs.contains(cell.id) }
        // Si ya pertenece al lugar con el mismo nombre, no hay nada que confirmar.
        if let mine=data.places.first(where:{$0.cellIDs.contains(cell.id)}),
           NamedPlaces.normalize(mine.name)==NamedPlaces.normalize(title) {
            return .assign(mine.id)
        }
        return NamedPlaces.proposal(cell:cell,name:title,places:excluding)
    }
    private func preserveNamesForUndo() {
        renameUndoSnapshot=(data.names,data.places)
        renameUndoAvailable=true
    }
    func assignName(_ cell:Cell, to rawName:String, groupID:UUID? = nil) {
        let name=rawName.trimmingCharacters(in:.whitespacesAndNewlines)
        if let current=data.places.first(where:{$0.cellIDs.contains(cell.id)}),
           current.id==groupID,NamedPlaces.normalize(name)==NamedPlaces.normalize(current.name) {
            // El usuario no ha cambiado de lugar: conservar su ID y sus otras casillas.
            if data.names[cell.id] != current.name {
                preserveNamesForUndo()
                data.names[cell.id]=current.name
                save(force:true)
            }
            return
        }
        preserveNamesForUndo()
        // Una cuadrícula solo tiene un lugar; cambiar el nombre abandona el anterior.
        for i in data.places.indices { data.places[i].cellIDs.removeAll { $0 == cell.id } }
        data.places.removeAll { $0.cellIDs.isEmpty }
        if name.isEmpty {
            data.names.removeValue(forKey:cell.id)
        } else {
            data.names[cell.id]=name
            let resolved:UUID?
            if let groupID { resolved=groupID }
            else {
                switch NamedPlaces.proposal(cell:cell,name:name,places:data.places) {
                case .assign(let id): resolved=id
                case .distant: resolved=nil // la UI debe pedir confirmación antes
                }
            }
            if let resolved,let index=data.places.firstIndex(where:{$0.id==resolved}) {
                data.names[cell.id]=data.places[index].name
                data.places[index].cellIDs.append(cell.id)
            } else {
                data.places.append(UserPlace(name:name,cellIDs:[cell.id]))
            }
        }
        save(force:true)
        refreshWidgets()
    }
    @discardableResult
    func undoLastRename() -> Bool {
        guard let snapshot=renameUndoSnapshot else { return false }
        data.names=snapshot.names
        data.places=snapshot.places
        renameUndoSnapshot=nil
        renameUndoAvailable=false
        save(force:true)
        refreshWidgets()
        return true
    }
    @discardableResult
    func renameWholePlace(_ placeID:UUID, to rawName:String) -> Bool {
        let name=rawName.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,let index=data.places.firstIndex(where:{$0.id==placeID}) else { return false }
        // No fusionar lugares de modo silencioso si hay homónimos preexistentes.
        if data.places.contains(where:{$0.id != placeID &&
                 NamedPlaces.normalize($0.name)==NamedPlaces.normalize(name)}) { return false }
        preserveNamesForUndo()
        data.places[index].name=name
        for id in data.places[index].cellIDs { data.names[id]=name }
        save(force:true)
        refreshWidgets()
        return true
    }
    func removePlace(_ place:UserPlace) {
        preserveNamesForUndo()
        for id in place.cellIDs { data.names.removeValue(forKey:id) }
        data.places.removeAll { $0.id == place.id }
        save(force:true)
        refreshWidgets()
    }
    func placeFor(_ cell:Cell) -> UserPlace? {
        data.places.first(where:{$0.cellIDs.contains(cell.id)})
    }
    func saveTerritory(_ value:TerritoryRecord, cellIDs:[String]) {
        for id in cellIDs { data.territoryCache[id] = value }
        save(force:true)
    }
    func routePoints(at now:Date = .now) -> [GPSPoint] {
        let lower: Date?
        switch routePeriod {
        case .lastTrip: lower = now.addingTimeInterval(-2*3600)
        case .today: lower = Calendar.current.startOfDay(for:now)
        case .day: lower = now.addingTimeInterval(-86400)
        case .week: lower = now.addingTimeInterval(-7*86400)
        case .all: lower = nil
        }
        let points = data.fixes.filter { ($0.date <= now) && (lower == nil || $0.date >= lower!) }
        return Array(points.suffix(12_000))
    }
    func rename(_ cell:Cell,to name:String) {
        // Los editores de nombre comprueban antes los homónimos remotos.
        assignName(cell,to:name)
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
        if retainedAge >= 120 || retainedDistance >= 16 || lastRetained?.cell != sample.cell {
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
        // Los nuevos intervalos deben ser monotónicos. Se conserva sin cambios
        // el historial antiguo, que se normaliza únicamente al consultarlo.
        let start=max(start,data.intervals.last?.end ?? start)
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
        assignShortID(cell.id)
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
        normalizedCacheIntervalCount = -1
        normalizedTotalsCache = [:]
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
                    kCLLocationAccuracyBest : kCLLocationAccuracyNearestTenMeters)
        else { return }
        mode = target
        if target == .precision {
            // Para cuadrículas de 100 m, Best basta sin navegación por segundo.
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 5
            manager.activityType = .fitness
            manager.pausesLocationUpdatesAutomatically = false
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 35
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
        model.recordPowerEvent(mode:mode,cause:"Inicio de seguimiento")
    }
    @MainActor func end(_ model: TimeModel) {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        motion.end()
        model.recording = false
        model.setTrackingEnabled(false)
        model.gpsStatus = "Detenido"
        model.recordPowerEvent(mode:mode,cause:"Seguimiento detenido")
        model.save(force:true)
        movingSoon = false
        decision = SmartGPSDecision()
        mode = .precision
    }
    @MainActor func refreshWhenForeground() {
        guard model?.recording == true,
              manager.authorizationStatus == .authorizedAlways ||
              manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestLocation()
        // La solicitud puntual no cancela la vigilancia inteligente en reposo.
    }
    @MainActor func setAnticipation(_ enabled: Bool) {
        if enabled { decision.anticipate() }
        else { decision.cancelAnticipation() }
        movingSoon = decision.movingSoon
        model?.recordPowerEvent(mode:decision.mode,
               cause:enabled ? "Voy a moverme activado" : "Anticipación desactivada manualmente")
        applyMode()
    }
    @MainActor private func applyMode() {
        movingSoon = decision.movingSoon
        if mode != decision.mode {
            let wakeFromRest = mode == .rest && decision.mode == .precision
            configure(decision.mode)
            if wakeFromRest { manager.startUpdatingLocation() }
            model?.recordPowerEvent(mode:decision.mode,
                 cause:decision.mode == .rest ? "Parada prolongada detectada" : "Movimiento detectado")
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
            TabView(selection:$model.selectedTab) {
                TimeMapView(model: model, gps: gps)
                    .tabItem { Label("Mapa", systemImage: "map") }.tag(0)
                TimeStatsDashboard(model: model)
                    .tabItem { Label("Estadísticas", systemImage: "chart.bar.fill") }.tag(1)
                GPSDiaryShell(model: model)
                    .tabItem { Label("Histórico", systemImage: "clock.arrow.circlepath") }.tag(2)
                TimeCompareView(model: model)
                    .tabItem { Label("Comparar", systemImage: "square.split.2x1") }.tag(3)
                TimeSettingsView(model: model, gps: gps)
                    .tabItem { Label("Ajustes", systemImage: "gearshape") }.tag(4)
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
    @State private var namingCell: Cell?
    @State private var historyCell: Cell?
    @State private var searchOpen = false
    @State private var queuedCellForMap: Cell?
    @State private var followLocation = false
    @State private var liveNow = Date()
    @Environment(\.scenePhase) private var scenePhase
    private let refreshClock = Timer.publish(every:1,on:.main,in:.common).autoconnect()
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
                .onAppear { centerOnRequestedCell() }
                .onChange(of:model.mapNavigationRevision) { _,_ in centerOnRequestedCell() }
            } else {
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(relevant) { cell in
                        MapPolygon(coordinates: Grid.polygon(cell))
                            .foregroundStyle(paint(model.total(for:cell)).opacity(0.52))
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
                        let recent = model.routePoints()
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
                        let touched=Grid.cell(latitude:coord.latitude,longitude:coord.longitude)
                        model.selected=touched
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { ctx in
                    region = ctx.region
                    model.updateCamera(ctx.region)
                    // MapKit abandona el modo de seguimiento al arrastrar/zoom manual.
                    if followLocation && !camera.followsUserLocation {
                        followLocation = false
                    }
                }
                .onAppear { centerOnRequestedCell() }
                .onChange(of:model.mapNavigationRevision) { _,_ in centerOnRequestedCell() }
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
                    Button { searchOpen=true } label: {
                        Image(systemName:"magnifyingglass").padding(11)
                            .background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                    }.accessibilityLabel("Buscar lugares y cuadrículas")
                    Button {
                        followLocation.toggle()
                        if followLocation {
                            model.selected=nil
                            if model.forceBasicMap || !connectivity.connected {
                                focusOnCurrentLocation()
                            } else {
                                camera = .userLocation(followsHeading:false,
                                       fallback:.region(region))
                            }
                            gps.refreshWhenForeground()
                        } else {
                            camera = .region(region)
                        }
                    } label: {
                        Image(systemName:followLocation ? "location.north.line.fill" : "location")
                            .foregroundStyle(followLocation ? Color.white : Color.primary)
                            .padding(11)
                            .background(followLocation ? Color.teal : Color(.secondarySystemBackground),
                                        in:RoundedRectangle(cornerRadius:12))
                    }
                    .accessibilityLabel(followLocation ? "Seguimiento activo; pasar a mapa libre" : "Mapa libre; seguir mi posición")
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
                // Los lugares se forman exclusivamente nombrando cuadrículas.
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
                if followLocation {
                    Text("Siguiéndome · toca la flecha para explorar libremente")
                        .font(.caption2).padding(.horizontal,16)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.selected.map { model.label(for:$0) } ??
                             (model.activeCell.map { model.label(for:$0) } ?? "Mi cuadrícula actual"))
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Button {
                            model.minimized.toggle()
                        } label: {
                            Image(systemName: model.minimized ? "chevron.up" : "chevron.down")
                        }.accessibilityLabel("Minimizar o expandir la tarjeta")
                    }
                    if !model.minimized {
                        let picked = model.selected ?? model.activeCell
                        VStack(alignment:.leading,spacing:7) {
                            let selectedPlace=picked.flatMap { model.placeFor($0) }
                            if let place=selectedPlace {
                                Text("Lugar · \(place.name)")
                                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                Text(DurationFormat.full(model.total(for:place,now:liveNow)))
                                    .font(.system(size:21,weight:.bold,design:.rounded))
                                    .lineLimit(1).minimumScaleFactor(0.65)
                            }
                            if let picked {
                                Text(selectedPlace == nil ? "Cuadrícula · tiempo acumulado" :
                                     "Esta cuadrícula · tiempo acumulado")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(DurationFormat.full(model.total(for:picked,now:liveNow)))
                                    .font(selectedPlace == nil ? .system(size:21,weight:.bold,design:.rounded) :
                                                                       .system(size:16,weight:.semibold,design:.rounded))
                                    .lineLimit(1).minimumScaleFactor(0.65)
                            }
                            HStack {
                                Text("Estancia actual (provisional)")
                                Spacer()
                                Text(picked == model.activeCell ?
                                     DurationFormat.full(model.staySeconds(now:liveNow)) : "—")
                            }.font(.footnote).foregroundStyle(.secondary)
                            if let age=model.gpsFixAge(now:liveNow),age>30 {
                                Text(age>120 ?
                                     "Sin GPS reciente (\(Int(age/60)) min). La estimación está detenida." :
                                     "Última posición hace \(Int(age)) s · avance provisional")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        HStack {
                            Label(model.gpsStatus, systemImage: "location.circle").font(.caption2)
                            Spacer()
                            if let cell = model.selected ?? model.activeCell {
                                Button("Histórico") { historyCell=cell }.font(.caption)
                                Button("Nombre") { namingCell=cell }.font(.caption)
                            }
                        }.foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(12)
            }
        }
        .sheet(item:$historyCell) { cell in
            NavigationStack {
                CellHistoryView(model:model,cell:cell)
                    .toolbar {
                        ToolbarItem(placement:.cancellationAction) {
                            Button("Cerrar") { historyCell=nil }
                        }
                    }
            }
        }
        .sheet(item:$namingCell) { cell in
            TimeNameEditor(model:model,cell:cell)
        }
        .sheet(isPresented:$searchOpen) {
            TimeUniversalSearch(model:model) { cell in
                queuedCellForMap=cell
                searchOpen=false
            }
        }
        .onChange(of:searchOpen) { _,open in
            if !open,let cell=queuedCellForMap {
                queuedCellForMap=nil
                model.navigate(to:cell)
            }
        }
        .onReceive(refreshClock) { value in
            if scenePhase == .active { liveNow=value }
        }
        .onChange(of:scenePhase) { _,phase in
            if phase == .active {
                liveNow = Date()
                gps.refreshWhenForeground()
                if followLocation && (model.forceBasicMap || !connectivity.connected) {
                    focusOnCurrentLocation()
                }
            }
        }
        .onChange(of:model.current?.date) { _,_ in
            if followLocation && (model.forceBasicMap || !connectivity.connected) {
                focusOnCurrentLocation()
            }
        }
    }
    private func focusOnCurrentLocation() {
        guard let position=model.current else { return }
        let target=MKCoordinateRegion(center:position.coordinate,span:region.span)
        region=target
        camera = .region(target)
    }
    private func centerOnRequestedCell() {
        if let c = model.targetMapCell {
            followLocation=false
            let center=Grid.center(c)
            let target=MKCoordinateRegion(center:center,
                   span:MKCoordinateSpan(latitudeDelta:0.003,longitudeDelta:0.003))
            region=target
            camera = .region(target)
            model.selected=c
            model.updateCamera(target)
        } else {
            camera = .region(model.data.camera.region)
            region = model.data.camera.region
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
                        (model.confirmedTotals()[$0.id] ?? 0) > (model.confirmedTotals()[$1.id] ?? 0)
                    }.prefix(30)) { cell in
                        LabeledContent(model.label(for: cell),
                                       value: DurationFormat.full(model.confirmedTotals()[cell.id] ?? 0))
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
    @AppStorage("timeWidgetShowPlace") private var showPlaceInWidgets = false
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
                    Toggle("Mostrar recorridos recientes", isOn:$model.showRoutes)
                        .onChange(of:model.showRoutes) { _,value in
                            UserDefaults.standard.set(value,forKey:"mapRoutesV5")
                        }
                    if model.showRoutes {
                        Picker("Recorridos visibles",selection:$model.routePeriod) {
                            ForEach(RouteDisplayPeriod.allCases) { period in
                                Text(period.label).tag(period)
                            }
                        }.onChange(of:model.routePeriod) { _,period in
                            UserDefaults.standard.set(period.rawValue,forKey:"mapRoutePeriodV5")
                        }
                    }
                    Toggle("Usar mapa básico (sin calles)", isOn:$model.forceBasicMap)
                    Text("Se activa automáticamente si no hay Internet; el mapa básico funciona sin descargar cartografía.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Escala de colores adaptada",isOn:$model.adaptive)
                        .onChange(of:model.adaptive) { _,value in
                            UserDefaults.standard.set(value,forKey:"mapAdaptiveV5")
                        }
                    Text("Permanencia: tiempo acumulado. Exploración: territorio descubierto. La escala adaptada resalta las diferencias entre cuadrículas visibles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Widgets iPhone") {
                    Text("Prueba de galería: esta compilación intenta registrar un widget de acceso al mapa sin depender de App Groups. Si aparece, se podrá tocar para abrir la aplicación; no mostrará duraciones GPS mientras no exista comunicación autorizada.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Mostrar nombres de lugares en widgets",isOn:$showPlaceInWidgets)
                        .disabled(!TimeWidgetStorage.isAvailable)
                        .onChange(of:showPlaceInWidgets) { _,_ in model.refreshWidgets() }
                    LabeledContent("Datos compartidos",
                        value: TimeWidgetStorage.isAvailable ? "Contenedor autorizado" : "No disponible con esta firma")
                    Text("La extensión compila y va incluida en la IPA, pero iOS aún no la muestra en tu galería. La firma real de Sideloadly y el registro del widget requieren diagnóstico en el iPhone. No prometemos contadores en widgets en esta versión.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("En la pantalla de inicio: mantén pulsado un espacio libre, toca Editar → Añadir widget y busca Mi Mapa del Tiempo. En la pantalla bloqueada: mantén pulsado, Personalizar y selecciona Widgets.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Si iOS llega a registrar la extensión sin App Group, mostrará un acceso a la aplicación. La visualización de tiempos dinámicos requiere una vía de datos compartidos autorizada.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text("El histórico, los lugares y la clasificación territorial se guardan en SQLite. Los territorios se clasifican bajo demanda, usando Internet y las consultas de Apple. Los widgets todavía pueden no aparecer con firmas gratuitas; no se garantiza su disponibilidad ni recarga. El consumo GPS debe contrastarse con pruebas reales.")
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