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
    var customZones: [TimeCustomZone] = []
    var territoryCache: [String:TerritoryRecord] = [:]
    // Private place identities and per-stay choices; original GPS history unchanged.
    var identifiedSites: [IdentifiedSite] = []
    var siteStayAssignments: [SiteStayAssignment] = []
    var siteStayParts: [SiteStayPart] = []
    var dismissedSiteStayKeys: [String] = []
    var powerEvents: [GPSPowerEvent] = []
    var shortIDs: [String:Int] = [:]
    // Persiste la intención de grabar para reanudar el seguimiento al abrir la app.
    var trackingEnabled = false
    var gpsRest: GPSRestSession?
    var dismissedGPSGapIDs:[String] = []

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
        gpsRest = try box.decodeIfPresent(GPSRestSession.self,forKey:.gpsRest)
        manualBreaks = try box.decodeIfPresent([Date].self,forKey:.manualBreaks) ?? []
        places = try box.decodeIfPresent([UserPlace].self,forKey:.places) ?? []
        customZones = try box.decodeIfPresent([TimeCustomZone].self,forKey:.customZones) ?? []
        territoryCache = try box.decodeIfPresent([String:TerritoryRecord].self,forKey:.territoryCache) ?? [:]
        identifiedSites = try box.decodeIfPresent([IdentifiedSite].self,forKey:.identifiedSites) ?? []
        siteStayAssignments = try box.decodeIfPresent([SiteStayAssignment].self,forKey:.siteStayAssignments) ?? []
        siteStayParts = try box.decodeIfPresent([SiteStayPart].self,forKey:.siteStayParts) ?? []
        dismissedSiteStayKeys = try box.decodeIfPresent([String].self,forKey:.dismissedSiteStayKeys) ?? []
        powerEvents = try box.decodeIfPresent([GPSPowerEvent].self,forKey:.powerEvents) ?? []
        shortIDs = try box.decodeIfPresent([String:Int].self,forKey:.shortIDs) ?? [:]
        dismissedGPSGapIDs = try box.decodeIfPresent([String].self,forKey:.dismissedGPSGapIDs) ?? []
    }
}
@MainActor final class TimeModel: ObservableObject {
    @Published private(set) var data = SavedState()
    // Lightweight visit summary cache: one-second card updates must never
    // rebuild the entire visit history. No new persisted fields or migrations.
    private var mapVisitCounts: [String: TimeMapVisitCounter.Snapshot] = [:]
    private var mapVisitFingerprint = ""
    @Published var current: GPSPoint?
    @Published var currentVisitStart: Date?
    @Published private(set) var currentZoneVisitStart: Date?
    @Published private(set) var currentZoneVisitID: UUID?
    @Published var selected: Cell?
    @Published var gpsStatus = "Sin iniciar"
    @Published var liveActivityDiagnostic = "Sin comprobar"
    @Published var recording = false
    @Published var explore = false
    @Published var adaptive = true
    @Published var cellFillOpacity: Double = 0.52
    @Published var showRoutes = true
    @Published var period: TimePeriod = .all
    @Published var mapKind: MKMapType = .standard
    @Published var minimized = false
    @Published var routePeriod: RouteDisplayPeriod = .today
    @Published var selectedTab = 0
    // The map view is recreated on tab changes. Keep follow mode in the
    // long-lived GPS model rather than resetting it every time.
    @Published var mapFollowLocation = false
    // A specific stay requested from an interactive notification.
    @Published var requestedSiteStayID: String?
    private var mapNavigation = MapNavigationOnce()
    @Published var mapNavigationRevision = UUID()
    @Published private(set) var renameUndoAvailable = false
    private var renameUndoSnapshot: (names:[String:String],places:[UserPlace])?
    var savedPowerEvents: [GPSPowerEvent] { data.powerEvents }
    var isResting: Bool { data.gpsRest != nil }
    var restingCell: Cell? { data.gpsRest?.cell }
    var restingCellName: String? { data.gpsRest.map { label(for: $0.cell) } }
    func pauseForRest(at date: Date = .now) -> Bool {
        guard recording, let point = current,
              date.timeIntervalSince(point.date) >= 0,
              date.timeIntervalSince(point.date) <= 180,
              let cell = activeCell else {
            gpsStatus = "Espera una posición GPS reciente antes de pausar"
            return false
        }
        let latest = lastProcessedSample?.date ?? point.date
        if date >= latest && date.timeIntervalSince(latest) <= 120 {
            addInterval(start:latest,end:date,cell:cell,
                        quality:"asumido · transición a pausa",source:"descanso")
        }
        if let zone=primaryZone(for:cell),currentZoneVisitID != zone.id {
            currentZoneVisitID=zone.id
            currentZoneVisitStart=TimeZoneVisit.beginning(
                in:data.intervals,zoneIDs:zone.cells,recentCell:cell,
                now:date,fallback:currentVisitStart ?? date)
        }
        data.gpsRest = GPSRestSession(startedAt: date, cell: cell,
                                      latitude: point.latitude, longitude: point.longitude)
        recording = false
        gpsStatus = "GPS en pausa · tiempo acumulándose en \(label(for:cell))"
        recordPowerEvent(mode:.rest,cause:"Pausa voluntaria desde \(label(for:cell))")
        // La actualización ActivityKit se enviará DESPUÉS de detener CoreLocation
        // y configurar la vigilancia de salida: no reentrar en SwiftUI aquí.
        return true
    }
    /// El periodo de reposo se consolida UNA sola vez cuando el GPS se reanuda.
    /// No se conecta con el primer fix nuevo: así no se duplica una noche en missingSeconds.
    func finishRest(at date: Date = .now) {
        guard let rest = data.gpsRest else { return }
        let end = max(date,rest.startedAt)
        if end > rest.startedAt {
            addInterval(start:rest.startedAt,end:end,cell:rest.cell,
                        quality:"asumido · pausa voluntaria",source:"descanso")
        }
        data.gpsRest = nil
        restContinuationStart = currentVisitStart
        restContinuationCell = rest.cell
        lastProcessedSample = nil
        stableCell = nil
        candidateCell = nil
        candidateSince = nil
        current = nil
        currentVisitStart = nil
        data.savedVisitStart = nil
        normalizedCacheIntervalCount = -1
        save(force:true)
        recordPowerEvent(mode:.precision,cause:"Pausa finalizada; tiempo asumido guardado")
        activityPublisher.refresh(from:self,force:true)
    }
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
    private let activityPublisher = TimeLiveActivityPublisher()
    private let territoryAutoClassifier = TerritoryAutoClassifier()
    private let fileURL: URL
    private var store: TimeSQLiteStore?
    @Published private var storageLoadFailed = false
    private var lastSafetyCopyAttempt = Date.distantPast
    var storageIsHealthy: Bool { !storageLoadFailed }
    /// Read the actual timestamp of an existing SQLite snapshot. This never
    /// creates a new copy and therefore causes no additional battery usage.
    var mostRecentLocalBackup: Date? {
        guard let latest = TimeSQLiteStore.safetyCopyURLs(
            in: fileURL.deletingLastPathComponent()).first else { return nil }
        return try? latest.resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    // Fast read-only index preserved while navigating between tabs.
    // No persistence changes and no loss of underlying GPS samples.
    var siteCalendarMemo: SiteCalendarMemo?
    private var lastProcessedSample: GPSPoint?
    private var restContinuationStart: Date?
    private var restContinuationCell: Cell?
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
    private var normalizedBuildRunning = false
    private var periodBuildRunning = false
    // A small published revision repaints consumers once an off-main result
    // arrives. Expensive canonicalization never runs in a SwiftUI body.
    @Published private(set) var totalsRefreshRevision = 0
    private var zoneCatalogCache:[TimeCustomZone]?
    private var zoneIndexCache:[String:Int]=[:]
    private var zoneOverlayCache:[TimeZoneOverlay]=[]
    private var zoneGeometryGeneration = UUID()
    @Published private(set) var zoneOverlayRevision = 0
    private var cachedPeriod:TimePeriod?
    private var cachedPeriodValues:[String:TimeInterval]=[:]
    private var cachedPeriodCount = -1
    private var cachedPeriodEnd:Date?
    private var cachedPeriodSince:Date = .distantPast
    private var cachedPeriodBucket: Int64 = -1

    /// Un índice para nombres/contornos. No reconstruir en cada muestra GPS.
    private func ensureZoneCatalog() {
        guard zoneCatalogCache == nil else { return }
        let zones=TimeZoneCatalog.visible(custom:data.customZones,legacy:data.places)
        var index:[String:Int]=[:]
        for (i,z) in zones.enumerated() {
            let size=z.cellIDs.count
            for id in z.cellIDs {
                if let other=index[id] {
                    let old=zones[other]
                    if size<old.cellIDs.count ||
                       (size==old.cellIDs.count &&
                        z.name.localizedStandardCompare(old.name) == .orderedAscending) {
                        index[id]=i
                    }
                } else { index[id]=i }
            }
        }
        zoneIndexCache=index
        zoneCatalogCache=zones
        // Build contours on a utility queue; a large zone can include 3,000
        // cells and must not block map gestures or live GPS callbacks.
        let generation = UUID()
        zoneGeometryGeneration = generation
        let outlines = Array(zones.prefix(18))
        DispatchQueue.global(qos:.utility).async {
            let projected = outlines.map { zone in
                TimeZoneOverlay(zone:zone,
                    contours:TimeZoneOutline.contours(for:zone),
                    center:TimeZoneOutline.visibleCenter(for:zone))
            }
            DispatchQueue.main.async {
                guard self.zoneGeometryGeneration == generation else { return }
                self.zoneOverlayCache = projected
                self.zoneOverlayRevision &+= 1
            }
        }
    }
    private func invalidateZoneCatalog() {
        zoneCatalogCache=nil
        zoneIndexCache.removeAll(keepingCapacity:true)
        zoneOverlayCache=[]
        zoneGeometryGeneration = UUID()
        zoneOverlayRevision &+= 1
    }
    var zoneOverlays:[TimeZoneOverlay] {
        ensureZoneCatalog()
        return zoneOverlayCache
    }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("time-map-v1.json")
        let legacy: SavedState? = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        do {
            let databaseURL = dir.appendingPathComponent("time-map-v3.sqlite")
            try TimeSQLiteStore.recoverMissingPrimary(at: databaseURL)
            let databaseExisted = FileManager.default.fileExists(atPath: databaseURL.path)
            let db = try TimeSQLiteStore(url: databaseURL)
            if databaseExisted {
                guard try db.headerExists() else { throw TimeStoreError.missingHeader }
            }
            try db.initializeIfTrulyEmpty(legacy ?? SavedState())
            data = try db.load()
            store = db
            // Preserve the six-hour backup interval across app relaunches.
            // Previously every launch could trigger another full SQLite copy.
            if let latestCopy = TimeSQLiteStore.safetyCopyURLs(in: dir).first,
               let modification = try? latestCopy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                lastSafetyCopyAttempt = modification
            }
            storeStatus = "SQLite · protegido localmente"
        } catch {
            // Si falla una migración, los datos anteriores siguen en el JSON original.
            data = legacy ?? SavedState()
            storageLoadFailed = true
            storeStatus = "ERROR DE ALMACENAMIENTO · no se guardarán cambios: \(error.localizedDescription)"
        }
        currentVisitStart = data.savedVisitStart
        if let resting = data.gpsRest,
           let zone=primaryZone(for:resting.cell) {
            currentZoneVisitID=zone.id
            currentZoneVisitStart=TimeZoneVisit.beginning(
                in:data.intervals,zoneIDs:zone.cells,recentCell:resting.cell,
                now:resting.startedAt,fallback:data.savedVisitStart ?? resting.startedAt)
        }
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
        cellFillOpacity = min(1,max(0.08,UserDefaults.standard.object(forKey:"mapCellOpacityV13") as? Double ?? 0.52))
        showRoutes = UserDefaults.standard.object(forKey:"mapRoutesV5") as? Bool ?? true
        routePeriod = RouteDisplayPeriod(rawValue:UserDefaults.standard.string(forKey:"mapRoutePeriodV5") ?? "") ?? .today
    }
    // Sólo una lista visible de zonas. La agrupación histórica de nombres sigue
    // conservada y cada UserPlace se presenta como una zona editable.
    var visibleZones: [TimeCustomZone] {
        ensureZoneCatalog()
        return zoneCatalogCache ?? []
    }
    func putZone(_ zone:TimeCustomZone) {
        guard !zone.cellIDs.isEmpty else { return }
        if let index=data.places.firstIndex(where:{$0.id == zone.id}) {
            // Una antigua agrupación con nombre se edita como zona sin duplicarla.
            let before=data.places[index]
            preserveNamesForUndo()
            let kept=Set(zone.cellIDs)
            for id in before.cellIDs where !kept.contains(id) {
                if data.names[id] == before.name { data.names.removeValue(forKey:id) }
            }
            for i in data.places.indices where i != index {
                data.places[i].cellIDs.removeAll(where:{ kept.contains($0) })
            }
            data.places.removeAll(where:{$0.cellIDs.isEmpty && $0.id != before.id})
            guard let newIndex=data.places.firstIndex(where:{$0.id == before.id}) else { return }
            data.places[newIndex].name=zone.name
            data.places[newIndex].cellIDs=zone.cellIDs
            for id in kept { data.names[id]=zone.name }
        } else if let index=data.customZones.firstIndex(where:{$0.id == zone.id}) {
            data.customZones[index]=zone
        } else {
            data.customZones.append(zone)
        }
        invalidateZoneCatalog()
        save(force:true)
        refreshLive()
    }
    func deleteZone(_ id:UUID) {
        if let original=data.places.first(where:{$0.id == id}) {
            removePlace(original)
        } else {
            data.customZones.removeAll(where:{$0.id == id})
            invalidateZoneCatalog()
            save(force:true)
        }
    }
    var totalSeconds: TimeInterval { confirmedTotals().values.reduce(0, +) }
    var allCells: [Cell] {
        data.totals.keys.compactMap {
            let a = $0.split(separator: ":")
            guard a.count == 2, let row = Int(a[0]), let col = Int(a[1]) else { return nil }
            return Cell(row: row, column: col)
        }
    }
    /// Same time filter as the Total column. Only a confirmed exit followed by
    /// re-entry creates another visit; a missing GPS fix alone does not.
    func numberOfVisits(for cellIDs:Set<String>,now:Date = .now) -> Int {
        guard !cellIDs.isEmpty else { return 0 }
        let window = TimeAnalytics.window(for:period,now:now)
        let first = data.intervals.first
        let last = data.intervals.last
        let bucket = TimeMapPeriodPolicy.refreshBucket(for: period, now: now)
        let fingerprint = "\(data.intervals.count)|\(first?.start.timeIntervalSince1970 ?? 0)|\(last?.start.timeIntervalSince1970 ?? 0)|\(last?.end.timeIntervalSince1970 ?? 0)|\(last?.cell.id ?? "")|\(period.rawValue)|\(bucket)"
        if fingerprint != mapVisitFingerprint {
            mapVisitFingerprint = fingerprint
            mapVisitCounts.removeAll(keepingCapacity:true)
        }
        let key = cellIDs.sorted().joined(separator:"|")
        let snapshot: TimeMapVisitCounter.Snapshot
        if let cached = mapVisitCounts[key] {
            snapshot = cached
        } else {
            snapshot = TimeMapVisitCounter.historical(data.intervals,
                        cellIDs:cellIDs,window:window)
            mapVisitCounts[key] = snapshot
        }
        return TimeMapVisitCounter.includingCurrent(snapshot,
                   currentCellID:activeCell?.id,cellIDs:cellIDs)
    }
    func confirmedTotals(now:Date = .now) -> [String:TimeInterval] {
        let count = data.intervals.count
        let lastEnd = data.intervals.last?.end
        let changed = count != normalizedCacheIntervalCount ||
                      lastEnd != normalizedCacheLastEnd
        if (normalizedCacheIntervalCount < 0 ||
             (changed && now.timeIntervalSince(normalizedCacheTime) >= 5)) &&
             !normalizedBuildRunning {
            normalizedBuildRunning = true
            normalizedCacheTime = now
            let snapshot = data.intervals
            DispatchQueue.global(qos:.utility).async {
                let calculated = TimeAttribution.byCell(snapshot)
                DispatchQueue.main.async {
                    self.normalizedBuildRunning = false
                    // A new GPS interval can arrive while normalization runs.
                    // The result is still a valid older snapshot, so show it
                    // immediately and schedule its successor on a later tick.
                    self.normalizedTotalsCache = calculated
                    self.normalizedCacheIntervalCount = count
                    self.normalizedCacheLastEnd = lastEnd
                    self.normalizedCacheTime = .now
                    self.totalsRefreshRevision &+= 1
                }
            }
        }
        // Saved totals give the user a useful first frame while the canonical
        // nonoverlapping view is being prepared in the background.
        return normalizedCacheIntervalCount < 0 ? data.totals : normalizedTotalsCache
    }
    func periodTotals(now: Date = .now) -> [String:TimeInterval] {
        guard let window = TimeAnalytics.window(for:period,now:now) else {
            return confirmedTotals(now:now)
        }
        let requestedPeriod = period
        let count = data.intervals.count
        let lastEnd = data.intervals.last?.end
        let bucket = TimeMapPeriodPolicy.refreshBucket(for:requestedPeriod,now:now)
        let changed = cachedPeriodCount != count || cachedPeriodEnd != lastEnd
        if (cachedPeriod != requestedPeriod || cachedPeriodBucket != bucket ||
            (changed && now.timeIntervalSince(cachedPeriodSince) >= 3)) &&
            !periodBuildRunning {
            periodBuildRunning = true
            let snapshot = data.intervals
            DispatchQueue.global(qos:.utility).async {
                let calculated = TimeAttribution.byCell(snapshot,window:window)
                DispatchQueue.main.async {
                    self.periodBuildRunning = false
                    // Never publish totals belonging to a different filter.
                    if self.period == requestedPeriod &&
                       TimeMapPeriodPolicy.refreshBucket(for:requestedPeriod,now:.now) == bucket {
                        self.cachedPeriodValues = calculated
                        self.cachedPeriod = requestedPeriod
                        self.cachedPeriodCount = count
                        self.cachedPeriodEnd = lastEnd
                        self.cachedPeriodSince = .now
                        self.cachedPeriodBucket = bucket
                        self.totalsRefreshRevision &+= 1
                    } else {
                        // A rapid filter switch takes priority over an obsolete
                        // calculation; the next job starts without a user tap.
                        _ = self.periodTotals(now:.now)
                    }
                }
            }
        }
        // On filter switches never display the previous period as current.
        return cachedPeriod == requestedPeriod && cachedPeriodBucket == bucket
            ? cachedPeriodValues : [:]
    }
    func confirmed(for cell:Cell,now:Date = .now) -> TimeInterval {
        periodTotals(now:now)[cell.id] ?? 0
    }
    // La estimación se muestra separada: nunca se persiste ni se atribuye
    // a intervalos GPS hasta comprobar una nueva posición.
    func provisionalSeconds(for cellIDs:Set<String>,now:Date = .now) -> TimeInterval {
        // confirmedTotals() puede seguir usando su caché de cinco segundos.
        // El reloj visible interpola desde EL FINAL DE ESA CACHÉ, no desde la
        // última muestra GPS. Así no retrocede a cero cuando llega cada fix.
        let cachedThrough:Date?
        if period == .all {
            cachedThrough = normalizedCacheLastEnd
        } else {
            // El cálculo de períodos acotados se actualiza en cada consulta.
            cachedThrough = cachedPeriodEnd
        }
        if let rest = data.gpsRest {
            guard cellIDs.contains(rest.cell.id) else { return 0 }
            return GPSRestPolicy.elapsed(start:rest.startedAt,end:now,
                lowerBound:TimeAnalytics.window(for:period,now:now)?.start)
        }
        return LiveCounterProjection.provisionalSeconds(
            recording:recording,
            currentLocationInTarget:activeCell.map { cellIDs.contains($0.id) } ?? false,
            lastFix:current?.date,
            cacheEnd:cachedThrough,
            currentVisitStart:currentVisitStart,
            periodStart:TimeAnalytics.window(for:period,now:now)?.start,
            now:now)
    }
    func gpsFixAge(now:Date = .now) -> TimeInterval? {
        guard let date=lastGPSFix else { return nil }
        return max(0,now.timeIntervalSince(date))
    }
    func total(for cell:Cell,now:Date = .now) -> TimeInterval {
        confirmed(for:cell,now:now)+provisionalSeconds(for:[cell.id],now:now)
    }
    func total(for zone:TimeCustomZone,now:Date = .now) -> TimeInterval {
        let totals=periodTotals(now:now)
        return zone.cells.reduce(0) { $0 + (totals[$1] ?? 0) } +
            provisionalSeconds(for:zone.cells,now:now)
    }
    func primaryZone(for cell:Cell) -> TimeCustomZone? {
        ensureZoneCatalog()
        guard let i=zoneIndexCache[cell.id], let zones=zoneCatalogCache,
              i<zones.count else { return nil }
        return zones[i]
    }
    func allZones(for cell:Cell) -> [TimeCustomZone] {
        visibleZones.filter { $0.cells.contains(cell.id) }
    }
    func total(for place:UserPlace,now:Date = .now) -> TimeInterval {
        let totals=periodTotals(now:now)
        return place.normalizedCellIDs.reduce(0){$0+(totals[$1] ?? 0)}
             + provisionalSeconds(for:place.normalizedCellIDs,now:now)
    }
    func zoneStaySeconds(for zone:TimeCustomZone,now:Date = .now) -> TimeInterval {
        guard currentZoneVisitID==zone.id,
              let cell=activeCell,zone.cellIDs.contains(cell.id) else { return 0 }
        return TimeZoneVisit.duration(start:currentZoneVisitStart,
                                     currentFix:current?.date,
                                     resting:isResting,now:now)
    }
    /// Una transición entre casillas de la misma zona NO reinicia su estancia.
    /// El histórico se consulta solo al entrar/reanudar la zona, nunca en cada
    /// refresco de los contadores ni al repintar el mapa.
    private func updateZoneVisit(cell:Cell,at date:Date,
                                 previousDate:Date?,preserveRest:Bool = false) {
        guard let zone=primaryZone(for:cell) else {
            currentZoneVisitID=nil
            currentZoneVisitStart=nil
            return
        }
        if currentZoneVisitID==zone.id,
           let previousDate, date.timeIntervalSince(previousDate)<=TimeZoneVisit.continuityGap {
            return
        }
        if currentZoneVisitID==zone.id && preserveRest { return }
        currentZoneVisitID=zone.id
        currentZoneVisitStart=TimeZoneVisit.beginning(
            in:data.intervals,zoneIDs:zone.cells,recentCell:cell,now:date,
            fallback:currentVisitStart ?? date)
    }
    func staySeconds(now: Date = .now) -> TimeInterval {
        if let rest = data.gpsRest {
            return max(0, now.timeIntervalSince(currentVisitStart ?? rest.startedAt))
        }
        guard recording, current != nil, let start = currentVisitStart,
              let lastFix=lastGPSFix else { return 0 }
        // Si iOS deja de proporcionar posiciones no se puede afirmar
        // que la estancia siga en la misma casilla indefinidamente.
        let provisionalEnd=min(now,lastFix.addingTimeInterval(120))
        return max(0, provisionalEnd.timeIntervalSince(start))
    }
    var activeCell: Cell? { data.gpsRest?.cell ?? stableCell ?? current?.cell }

    var siteThresholdMinutes: Int {
        let setting = UserDefaults.standard.integer(forKey: "siteRecognitionMinutesV56")
        return SiteStayPolicy.allowedThresholds.contains(setting)
               ? setting : SiteStayPolicy.defaultThresholdMinutes
    }
    func setSiteThresholdMinutes(_ minutes: Int) {
        guard SiteStayPolicy.allowedThresholds.contains(minutes) else { return }
        UserDefaults.standard.set(minutes, forKey: "siteRecognitionMinutesV56")
        evaluateCurrentSite()
        objectWillChange.send()
    }
    private func currentSiteVisit(for cell: Cell, now: Date) -> (Date, TimeInterval)? {
        guard activeCell == cell, let start = currentVisitStart,
              start <= now, storageIsHealthy else { return nil }
        // This already enforces the 120-second stale-GPS cap and rest policy.
        let elapsed = staySeconds(now: now)
        guard elapsed > 0 else { return nil }
        return (start, elapsed)
    }
    func siteDecision(for cell: Cell, now: Date = .now) -> SiteStayDecision {
        guard let (start, elapsed) = currentSiteVisit(for: cell, now: now) else {
            return .tooEarly
        }
        return SiteStayPolicy.decision(cellID: cell.id, entered: start,
                    elapsed: elapsed, thresholdMinutes: siteThresholdMinutes,
                    sites: data.identifiedSites, assignments: data.siteStayAssignments,
                    dismissedKeys: Set(data.dismissedSiteStayKeys),
                    parts: data.siteStayParts)
    }
    func spatialSiteCandidates(for cell: Cell) -> [SiteSpatialCandidate] {
        SiteCrossGridPolicy.candidates(for:cell,sites:data.identifiedSites,
                  assignments:data.siteStayAssignments,parts:data.siteStayParts)
    }
    func preferredSiteID(for cellID: String) -> UUID? {
        // Strict rule: ONLY confirmations in this exact 100m grid square.
        // A venue suggested from another square must never silently inherit
        // its time, even if the establishment is large or the pin is nearby.
        SiteStayPolicy.rankedSiteIDs(data.siteStayAssignments,cellID:cellID,
                      validIDs:Set(data.identifiedSites.map(\.id)),
                      parts:data.siteStayParts).first
    }
    /// One-time cleanup of cross-grid guesses recorded by older builds.
    /// Human confirmations and GPS intervals are strictly preserved.
    func discardUnsupportedAutomaticSiteAssignments() {
        guard storageIsHealthy else { return }
        var permitted:Set<String> = []
        for entry in data.siteStayAssignments where entry.confirmed {
            permitted.insert(entry.cellID + "|" + entry.siteID.uuidString)
        }
        for part in data.siteStayParts where part.confirmed && part.kind == .place {
            guard let id=part.siteID,let separator=part.stayID.firstIndex(of:"|") else { continue }
            permitted.insert(String(part.stayID[..<separator]) + "|" + id.uuidString)
        }
        let before=data.siteStayAssignments.count
        data.siteStayAssignments.removeAll {
            !$0.confirmed && !permitted.contains($0.cellID + "|" + $0.siteID.uuidString)
        }
        guard before != data.siteStayAssignments.count else { return }
        save(force:true)
        objectWillChange.send()
    }
    func siteParts(for stay: SiteGridStay) -> [SiteStayPart] {
        let explicit = data.siteStayParts.filter { $0.stayID == stay.id }
        if SiteStayHistory.valid(explicit,for:stay) {
            // Only historical labels that were NEVER confirmed may be updated
            // when the same place is confirmed in another square. A manual
            // multi-site division, a passing marker and all confirmations stay.
            if explicit.count == 1, let only=explicit.first,
               only.kind == .place && !only.confirmed {
                var proposed=only
                if let candidate=preferredSiteID(for:stay.cell.id) {
                    proposed.siteID=candidate
                } else {
                    // A suggested place without evidence from this square
                    // is not displayed as if the user had visited it.
                    proposed.siteID=nil
                    proposed.kind = .unassigned
                }
                return [proposed]
            }
            return explicit.sorted { $0.from < $1.from }
        }
        let legacy = data.siteStayAssignments.first { $0.id == stay.id && $0.confirmed }
        var proposed = SiteStayHistory.defaultPart(for:stay,
                suggested: legacy?.siteID ?? preferredSiteID(for:stay.cell.id))
        // A notification's Confirmado action is a real confirmation, and
        // must remain confirmed while the ongoing GPS stay keeps growing.
        proposed.confirmed = legacy != nil
        return [proposed]
    }
    func writeSiteParts(_ parts: [SiteStayPart], stay: SiteGridStay) {
        guard SiteStayHistory.valid(parts,for:stay), storageIsHealthy else { return }
        data.siteStayParts.removeAll { $0.stayID == stay.id }
        data.siteStayParts.append(contentsOf:parts)
        // Historic edits replace this stay's older single-site assignment.
        data.siteStayAssignments.removeAll { $0.id == stay.id }
        save(force:true)
        activityPublisher.refresh(from:self,force:true)
        objectWillChange.send()
    }
    func createOrReuseSite(name:String, latitude:Double, longitude:Double,
                           origin:String) -> IdentifiedSite? {
        let title=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty, latitude.isFinite, longitude.isFinite,
              abs(latitude)<=90, abs(longitude)<=180,storageIsHealthy else { return nil }
        let coordinate=CLLocation(latitude:latitude,longitude:longitude)
        if let previous=data.identifiedSites.first(where: {
            $0.name.compare(title,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame &&
            CLLocation(latitude:$0.latitude,longitude:$0.longitude)
              .distance(from:coordinate)<60
        }) { return previous }
        let created=IdentifiedSite(name:title,latitude:latitude,longitude:longitude,origin:origin)
        data.identifiedSites.append(created)
        save(force:true)
        return created
    }
    func createPrivateSite(name:String,cell:Cell) -> IdentifiedSite? {
        guard storageIsHealthy else { return nil }
        let title=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let coordinate=Grid.center(cell)
        let position=CLLocation(latitude:coordinate.latitude,longitude:coordinate.longitude)
        if let saved=data.identifiedSites.first(where:{
            $0.origin == "private" &&
            $0.name.compare(title,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame &&
            CLLocation(latitude:$0.latitude,longitude:$0.longitude)
                .distance(from:position) < 60
        }) { return saved }
        // Do not re-use a map-provider record as a "private" place:
        // the user's own place must remain editable and removable.
        let site=IdentifiedSite(name:title,latitude:coordinate.latitude,
                                longitude:coordinate.longitude,origin:"private")
        data.identifiedSites.append(site)
        save(force:true)
        return site
    }
    /// Save edits to a user-created site. Existing stay references keep the
    /// same UUID, so all history instantly adopts its corrected name and pin.
    @discardableResult
    func updatePrivateSite(id:UUID,name:String,latitude:Double,longitude:Double) -> Bool {
        guard storageIsHealthy else { return false }
        let succeeded=SitePrivateManagement.update(id:id,name:name,latitude:latitude,
                                         longitude:longitude,sites:&data.identifiedSites)
        guard succeeded else { return false }
        save(force:true)
        activityPublisher.refresh(from:self,force:true)
        objectWillChange.send()
        return true
    }

    func privateSiteLinkedStayCount(_ id:UUID) -> Int {
        SitePrivateManagement.linkedStays(id:id,assignments:data.siteStayAssignments,
                                          parts:data.siteStayParts)
    }

    /// Remove ONLY the private-place identity and links to that identity.
    /// Keep all GPS observations, intervals, grid cells, recorded minutes and
    /// independently assigned sites for other sub-periods unchanged.
    @discardableResult
    func deletePrivateSite(_ id:UUID) -> Bool {
        guard storageIsHealthy else { return false }
        var sites=data.identifiedSites
        var assignments=data.siteStayAssignments
        var parts=data.siteStayParts
        guard sites.contains(where:{ $0.id == id && $0.origin == "private" }) else {
            return false
        }
        // Only affected legacy stays get explicit "Sin identificar".
        // Existing edited multi-site splits are preserved as-is.
        let unassigned=SitePrivateManagement.unassignedPartsForDeletedLegacy(
            id:id,assignments:assignments,intervals:data.intervals,
            existingParts:parts)
        guard SitePrivateManagement.delete(id:id,sites:&sites,
                   assignments:&assignments,parts:&parts) else { return false }
        parts.append(contentsOf:unassigned)
        data.identifiedSites=sites
        data.siteStayAssignments=assignments
        data.siteStayParts=parts
        save(force:true)
        activityPublisher.refresh(from:self,force:true)
        objectWillChange.send()
        return true
    }

    func siteNamed(_ id: UUID) -> IdentifiedSite? {
        data.identifiedSites.first { $0.id == id }
    }

    /// Confirm exactly the visible Histórico de sitios row named by
    /// groupID, including ALL its constituent 100m GPS stays. Revalidate
    /// against the latest calendar grouping before touching saved choices.
    @discardableResult
    func confirmNotifiedStay(stayID groupID: String,
                             expectedSiteID: UUID) -> Bool {
        guard storageIsHealthy, siteNamed(expectedSiteID) != nil else { return false }
        let stays = SiteStayHistory.extract(data.intervals)
        guard let first = stays.first(where: { $0.id == groupID }) else { return false }
        let index = SiteDayPartsIndex(assignments:data.siteStayAssignments,
                       parts:data.siteStayParts, sites:data.identifiedSites)
        let sources = stays.map { SiteDaySource(stay:$0,
                                               parts:index.parts(for:$0)) }
        let report = SiteDayPresentation.build(sources,on:first.start)
        guard let group = report.groups.first(where:{$0.id == groupID}),
              group.siteID == expectedSiteID, !group.confirmed else { return false }

        // Atomic verification: no partial confirmations and no overwriting
        // a different place manually assigned since this notification.
        for entry in group.entries {
            let parts = index.parts(for:entry.stay)
            guard parts.count == 1, let only = parts.first,
                  only.kind == .place, only.siteID == expectedSiteID,
                  !only.confirmed else { return false }
        }
        for entry in group.entries {
            let raw = data.siteStayParts.indices.filter {
                data.siteStayParts[$0].stayID == entry.stay.id
            }
            if raw.count == 1,
               data.siteStayParts[raw[0]].kind == .place,
               data.siteStayParts[raw[0]].siteID == expectedSiteID,
               SiteStayHistory.valid([data.siteStayParts[raw[0]]],
                                     for:entry.stay) {
                data.siteStayParts[raw[0]].confirmed = true
            } else {
                data.siteStayAssignments = SiteStayPolicy.select(
                    siteID:expectedSiteID,cellID:entry.stay.cell.id,
                    entered:entry.stay.start,assignments:data.siteStayAssignments)
            }
        }
        save(force:true)
        activityPublisher.refresh(from:self,force:true)
        objectWillChange.send()
        return true
    }

    /// Show the same GROUP in the historical list, including its sub-stays
    /// if it spans more than one square.
    func openNotifiedStay(stayID: String) {
        requestedSiteStayID = stayID
        selectedTab = 3
    }

    func siteOptions(for cell: Cell) -> [(site: IdentifiedSite, confirmations: Int, fromOtherSquares: Int)] {
        let votes = SiteStayPolicy.confirmedCounts(data.siteStayAssignments,
                                cellID: cell.id, parts: data.siteStayParts)
        let ranked = spatialSiteCandidates(for:cell)
        let already = Set(ranked.map(\.siteID))
        let center = Grid.center(cell)
        let origin = CLLocation(latitude:center.latitude,longitude:center.longitude)
        let extras = data.identifiedSites.filter { site in
            guard !already.contains(site.id) else { return false }
            return origin.distance(from:CLLocation(
                latitude:site.latitude,longitude:site.longitude)) < 120
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let known:[(site:IdentifiedSite,confirmations:Int,fromOtherSquares:Int)] =
            ranked.compactMap { candidate in
                guard let site=siteNamed(candidate.siteID) else { return nil }
                return (site:site,confirmations:votes[site.id] ?? 0,
                        fromOtherSquares:candidate.confirmedCells
                            .filter { $0 != cell.id }.count)
            }
        return known + extras.map {
            (site:$0,confirmations:0,fromOtherSquares:0)
        }
    }
    /// Automatic choice is a lightweight local operation called after GPS
    /// callbacks and while the map is active. No network query or notification.
    func evaluateCurrentSite(now: Date = .now) {
        guard let cell = activeCell,
              let (start, elapsed) = currentSiteVisit(for: cell, now: now),
              isResting || ((lastAccuracy ?? 999) <= 75 &&
                  (lastGPSFix.map { now.timeIntervalSince($0) < 120 } ?? false))
              else { return }
        let localChoice = SiteStayPolicy.automaticChoice(
              cellID: cell.id, entered: start, elapsed: elapsed,
              thresholdMinutes: siteThresholdMinutes,
              sites: data.identifiedSites,
              assignments: data.siteStayAssignments,
              dismissedKeys: Set(data.dismissedSiteStayKeys),
              parts: data.siteStayParts)
        // An existing assignment for this visit must never be appended again,
        // even if another nearby venue later becomes a candidate.
        let key = SiteStayPolicy.visitKey(cellID: cell.id, entered: start)
        guard !data.siteStayAssignments.contains(where: { $0.id == key }) else { return }
        // Nearby POIs are only suggestions; automatic decisions require
        // an explicit confirmation in the exact current grid square.
        guard let chosen = localChoice else { return }
        data.siteStayAssignments.append(SiteStayAssignment(id: key, cellID: cell.id,
                       startedAt: start, siteID: chosen, confirmed: false))
        save(force: true)
        activityPublisher.refresh(from:self,force:true)
    }
    func dismissSitePrompt(in cell: Cell) {
        guard let (start, _) = currentSiteVisit(for: cell, now: .now) else { return }
        let key = SiteStayPolicy.visitKey(cellID: cell.id, entered: start)
        guard !data.dismissedSiteStayKeys.contains(key) else { return }
        data.dismissedSiteStayKeys.append(key)
        if data.dismissedSiteStayKeys.count > 500 {
            data.dismissedSiteStayKeys.removeFirst(data.dismissedSiteStayKeys.count - 500)
        }
        save(force: true)
    }
    func confirmSite(_ site: IdentifiedSite, cell: Cell, now: Date = .now) {
        guard let (start, _) = currentSiteVisit(for: cell, now: now) else { return }
        guard !site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !data.identifiedSites.contains(where: { $0.id == site.id }) {
            data.identifiedSites.append(site)
        }
        let key = SiteStayPolicy.visitKey(cellID: cell.id, entered: start)
        data.siteStayAssignments = SiteStayPolicy.select(siteID: site.id,
                           cellID: cell.id, entered: start,
                           assignments: data.siteStayAssignments)
        data.dismissedSiteStayKeys.removeAll { $0 == key }
        save(force: true)
        activityPublisher.refresh(from:self,force:true)
    }
    func confirmAppleSite(name: String, latitude: Double, longitude: Double, cell: Cell) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, latitude.isFinite, longitude.isFinite else { return }
        let coordinate = CLLocation(latitude: latitude, longitude: longitude)
        let match = data.identifiedSites.first { old in
            guard old.name.compare(trimmed, options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame else {
                return false
            }
            return CLLocation(latitude:old.latitude,longitude:old.longitude).distance(from:coordinate) < 60
        }
        confirmSite(match ?? IdentifiedSite(name:trimmed,latitude:latitude,
                                   longitude:longitude,origin:"apple"),cell:cell)
    }
    func confirmPrivateSite(name: String, cell: Cell) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let point = activeCell == cell ? (current?.coordinate ?? Grid.center(cell)) : Grid.center(cell)
        let same = data.identifiedSites.first {
            $0.origin == "private" &&
            $0.name.compare(trimmed, options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame &&
            Grid.cell(latitude:$0.latitude,longitude:$0.longitude) == cell
        }
        confirmSite(same ?? IdentifiedSite(name:trimmed,latitude:point.latitude,
                                          longitude:point.longitude,origin:"private"),cell:cell)
    }
    func reactivateLiveActivity() { activityPublisher.reactivate(from:self) }
    func restoreLiveActivityIfNeeded() { activityPublisher.restoreIfNeeded(from:self) }
    func checkLockScreen() { activityPublisher.check(from:self) }
    func refreshLive() {
        activityPublisher.refresh(from:self)
    }
    func setLockScreenEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled,forKey:"miMapaLiveActivity")
        activityPublisher.refresh(from:self,force:true)
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
        if let zone=primaryZone(for:cell) { return zone.name }
        return FriendlyCellName.title(cell,index:data.shortIDs[cell.id],custom:data.names[cell.id])
    }
    private func assignShortID(_ id:String) {
        guard data.shortIDs[id] == nil else { return }
        data.shortIDs[id] = (data.shortIDs.values.max() ?? 0)+1
    }
    func hasCustomName(_ id: String) -> Bool {
        ensureZoneCatalog()
        return zoneIndexCache[id] != nil ||
            !(data.names[id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    func navigate(to cell: Cell) {
        selected = cell
        mapNavigation.enqueue(cell)
        mapNavigationRevision=UUID() // permite navegar dos veces a la misma zona
        selectedTab = 0
    }
    func takeMapTarget() -> Cell? { mapNavigation.consume() }
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
        invalidateZoneCatalog()
        save(force:true)
        refreshLive()
    }
    @discardableResult
    func undoLastRename() -> Bool {
        guard let snapshot=renameUndoSnapshot else { return false }
        data.names=snapshot.names
        data.places=snapshot.places
        renameUndoSnapshot=nil
        renameUndoAvailable=false
        invalidateZoneCatalog()
        save(force:true)
        refreshLive()
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
        invalidateZoneCatalog()
        save(force:true)
        refreshLive()
        return true
    }
    func removePlace(_ place:UserPlace) {
        preserveNamesForUndo()
        for id in place.cellIDs { data.names.removeValue(forKey:id) }
        data.places.removeAll { $0.id == place.id }
        invalidateZoneCatalog()
        save(force:true)
        refreshLive()
    }
    func placeFor(_ cell:Cell) -> UserPlace? {
        data.places.first(where:{$0.cellIDs.contains(cell.id)})
    }
    func saveTerritory(_ value:TerritoryRecord, cellIDs:[String]) {
        let alreadyKnown=data.territoryCache.values.contains {
            $0.city?.localizedCaseInsensitiveCompare(value.city ?? "") == .orderedSame &&
            $0.country?.localizedCaseInsensitiveCompare(value.country ?? "") == .orderedSame
        }
        for id in cellIDs { data.territoryCache[id] = value }
        save(force:true)
        GPSPersonalAlerts.shared.discoveredCity(value,seenBefore:alreadyKnown)
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
        guard !enabled || storageIsHealthy else {
            gpsStatus = "GPS detenido · almacenamiento no disponible"
            return
        }
        data.trackingEnabled = enabled
        save(force: true)
        activityPublisher.refresh(from:self,force:true)
    }
    /// La confirmación siempre devuelve el resultado real de la persistencia.
    /// Se hace INSERT transaccional del intervalo estimado, no replaceAll del
    /// histórico entero, para evitar bloqueos y preservar el GPS en marcha.
    @discardableResult
    func confirmUnobservedStay(_ gap:TimeGPSGapCandidate)->TimeGPSGapConfirmationOutcome {
        // La sesión actual puede estar en pausa. Eso NO invalida los huecos
        // históricos que terminaron ANTES de comenzar esa pausa.
        guard TimeGPSGapRecovery.compatibleWithRest(gap,rest:data.gpsRest) else {
            gpsStatus="El hueco se solapa con la pausa GPS actual"
            return .overlapsCurrentRest
        }
        let stillAvailable=TimeGPSGapRecovery.candidates(
            intervals:data.intervals,fixes:data.fixes,
            manualBreaks:data.manualBreaks,events:data.powerEvents,
            cells:[gap.cell.id]).contains(gap)
        guard stillAvailable else {
            if data.intervals.contains(where: {
                $0.source=="confirmacion_usuario" &&
                $0.cell==gap.cell &&
                $0.start<gap.end && $0.end>gap.start
            }) {
                gpsStatus="Este hueco ya fue recuperado"
                return .alreadySaved
            }
            gpsStatus="Confirmación no aplicada · intervalo cambiado"
            return .noLongerAvailable
        }
        var updated=data
        let recovery=AssignedInterval(start:gap.start,end:gap.end,
            cell:gap.cell,quality:"asumido · confirmado por usuario",
            source:"confirmacion_usuario")
        updated.intervals.append(recovery)
        updated.intervals.sort { $0.start<$1.start }
        updated.totals[gap.cell.id,default:0]+=recovery.seconds
        do {
            if let store {
                // Incluimos posiciones e intervalos pendientes sin perderlos
                // y escribimos todo en una única transacción SQLite.
                var deltas=pendingTotals
                deltas[gap.cell.id,default:0]+=recovery.seconds
                try store.append(fixes:pendingFixes,
                    intervals:pendingIntervals+[recovery],
                    totals:deltas,header:TimeStoreHeader(updated))
            } else {
                try JSONEncoder().encode(updated).write(to:fileURL,options:.atomic)
            }
            data=updated
            pendingFixes.removeAll(keepingCapacity:true)
            pendingIntervals.removeAll(keepingCapacity:true)
            pendingTotals.removeAll(keepingCapacity:true)
            normalizedCacheIntervalCount = -1
            normalizedCacheTime = .distantPast
            cachedPeriod = nil
            cachedPeriodCount = -1
            cachedPeriodSince = .distantPast
            lastSaved = .now
            gpsStatus="Recuperados \(DurationFormat.full(recovery.seconds)) como tiempo estimado"
            activityPublisher.refresh(from:self,force:true)
            objectWillChange.send()
            return .saved(recovery.seconds)
        } catch {
            // El modelo visible NO se modifica al fallar el guardado.
            let message=error.localizedDescription
            gpsStatus="No se pudo guardar la confirmación: \(message)"
            return .storageFailure(message)
        }
    }
    /// Revisión general: permite recuperar huecos incluso con dos cuadrículas
    /// diferentes o con pocos anclajes, SIEMPRE como tiempo asumido explícito.
    /// La presencia GPS observada no se modifica nunca.
    @discardableResult
    func confirmReviewedGap(_ gap:TimeGPSGapReview,
                            choice:TimeGPSGapChoice)->TimeGPSGapConfirmationOutcome {
        guard gap.canManuallyAssign else { return .noLongerAvailable }
        guard data.gpsRest.map({gap.end<=$0.startedAt}) ?? true else {
            return .overlapsCurrentRest
        }
        let present=TimeGPSGapReviewIndex.scan(
            intervals:data.intervals,fixes:data.fixes,
            events:data.powerEvents,
            dismissed:Set(data.dismissedGPSGapIDs))
        guard present.contains(gap) else {
            return .noLongerAvailable
        }
        let pieces=TimeGPSGapReviewIndex.segments(for:gap,choice:choice)
        guard !pieces.isEmpty else { return .noLongerAvailable }
        var updated=data
        updated.intervals.append(contentsOf:pieces)
        updated.intervals.sort { $0.start<$1.start }
        var deltas=pendingTotals
        for piece in pieces {
            updated.totals[piece.cell.id,default:0]+=piece.seconds
            deltas[piece.cell.id,default:0]+=piece.seconds
        }
        do {
            if let store {
                try store.append(fixes:pendingFixes,
                    intervals:pendingIntervals+pieces,totals:deltas,
                    header:TimeStoreHeader(updated))
            } else {
                try JSONEncoder().encode(updated).write(to:fileURL,options:.atomic)
            }
            data=updated
            pendingFixes.removeAll(keepingCapacity:true)
            pendingIntervals.removeAll(keepingCapacity:true)
            pendingTotals.removeAll(keepingCapacity:true)
            normalizedCacheIntervalCount = -1
            normalizedCacheTime = .distantPast
            cachedPeriod = nil
            cachedPeriodCount = -1
            cachedPeriodSince = .distantPast
            lastSaved = .now
            gpsStatus="Recuperados \(DurationFormat.full(gap.seconds)) como estimados"
            activityPublisher.refresh(from:self,force:true)
            objectWillChange.send()
            return .saved(gap.seconds)
        } catch {
            gpsStatus="Error de recuperación: \(error.localizedDescription)"
            return .storageFailure(error.localizedDescription)
        }
    }

    /// Guarda exclusivamente tramos estimados, por todas las cuadrículas
    /// cruzadas en el mapa editado. Mismo contrato atómico que los otros
    /// métodos de recuperación y sin tocar puntos GPS observados.
    @discardableResult
    func confirmEstimatedRoute(_ gap:TimeGPSGapReview,
                               plan:GPSGapRoutePlan)->TimeGPSGapConfirmationOutcome {
        guard gap.id==plan.gapID, gap.seconds<=GPSGapRoutePlanner.maxSeconds,
              !gap.contradictoryGPS,
              data.gpsRest.map({ gap.end<=$0.startedAt }) ?? true else {
            return .noLongerAvailable
        }
        let stillPresent=TimeGPSGapReviewIndex.scan(
            intervals:data.intervals,fixes:data.fixes,events:data.powerEvents,
            dismissed:Set(data.dismissedGPSGapIDs)).contains(gap)
        guard stillPresent else { return .noLongerAvailable }
        let segments=plan.intervals()
        guard !segments.isEmpty,
              segments.first?.start==gap.start,
              segments.last?.end==gap.end,
              abs(plan.seconds-gap.seconds)<0.001,
              segments.count<=GPSGapRoutePlanner.maxCells,
              segments.allSatisfy({
                  $0.source=="recorrido_estimado" &&
                  $0.seconds>0 &&
                  $0.start>=gap.start && $0.end<=gap.end
              }) else { return .noLongerAvailable }
        for i in 1..<segments.count {
            guard abs(segments[i].start.timeIntervalSince(segments[i-1].end))<0.001
            else { return .noLongerAvailable }
        }
        // Evita superponer otros intervalos, incluso si se añadieron
        // mientras el usuario estaba inspeccionando el mapa.
        guard !data.intervals.contains(where:{
            $0.end>gap.start && $0.start<gap.end
        }) else { return .noLongerAvailable }

        var updated=data
        updated.intervals.append(contentsOf:segments)
        updated.intervals.sort { $0.start<$1.start }
        var deltas=pendingTotals
        for part in segments {
            updated.totals[part.cell.id,default:0]+=part.seconds
            deltas[part.cell.id,default:0]+=part.seconds
        }
        do {
            if let store {
                try store.append(fixes:pendingFixes,
                    intervals:pendingIntervals+segments,
                    totals:deltas,header:TimeStoreHeader(updated))
            } else {
                try JSONEncoder().encode(updated).write(to:fileURL,options:.atomic)
            }
            data=updated
            pendingFixes.removeAll(keepingCapacity:true)
            pendingIntervals.removeAll(keepingCapacity:true)
            pendingTotals.removeAll(keepingCapacity:true)
            normalizedCacheIntervalCount = -1
            normalizedCacheTime = .distantPast
            cachedPeriod = nil
            cachedPeriodCount = -1
            cachedPeriodSince = .distantPast
            lastSaved = .now
            gpsStatus="Reparto estimado confirmado en \(plan.cells.count) cuadrículas"
            activityPublisher.refresh(from:self,force:true)
            objectWillChange.send()
            return .saved(gap.seconds)
        } catch {
            gpsStatus="No se pudo guardar el reparto: \(error.localizedDescription)"
            return .storageFailure(error.localizedDescription)
        }
    }

    /// Revierte o recoloca tiempo ESTIMADO, nunca modifica lecturas GPS.
    /// replaceAll usa una única transacción SQLite y conserva los pendientes.
    @discardableResult
    func reviseRecoveredTime(_ group:TimeRecoveryGroup,
                             newCell:Cell?)->Bool {
        let existing=Set(data.intervals.map(\.id))
        guard group.intervals.allSatisfy({
            existing.contains($0.id) && TimeRecoveryIndex.sources.contains($0.source)
        }) else {
            gpsStatus="La recuperación ha cambiado. Vuelve a abrir el historial."
            return false
        }
        var updated=data
        updated.intervals=TimeRecoveryIndex.without(updated.intervals,group:group)
        if let newCell {
            updated.intervals.append(contentsOf:TimeRecoveryIndex.reassigned(group,cell:newCell))
        }
        updated.intervals.sort { $0.start<$1.start }
        updated.totals=TimeAttribution.byCell(updated.intervals)
        do {
            if let store {
                try store.replaceAll(updated)
            } else {
                try JSONEncoder().encode(updated).write(to:fileURL,options:.atomic)
            }
            data=updated
            pendingFixes.removeAll(keepingCapacity:true)
            pendingIntervals.removeAll(keepingCapacity:true)
            pendingTotals.removeAll(keepingCapacity:true)
            normalizedTotalsCache=[:]
            normalizedCacheIntervalCount = -1
            normalizedCacheTime = .distantPast
            cachedPeriod = nil
            cachedPeriodCount = -1
            cachedPeriodSince = .distantPast
            lastSaved = .now
            gpsStatus = newCell == nil ? "Recuperación deshecha" :
                "Recuperación corregida sin cambiar datos GPS"
            activityPublisher.refresh(from:self,force:true)
            objectWillChange.send()
            return true
        } catch {
            gpsStatus="No se pudo corregir el historial: \(error.localizedDescription)"
            return false
        }
    }

    /// Descarta la sugerencia, sin borrar ningún intervalo ni una posición.
    @discardableResult func dismissReviewedGap(_ gap:TimeGPSGapReview)->Bool {
        var updated=data
        if !updated.dismissedGPSGapIDs.contains(gap.id) {
            updated.dismissedGPSGapIDs.append(gap.id)
        }
        do {
            if let store {
                try store.append(fixes:pendingFixes,intervals:pendingIntervals,
                    totals:pendingTotals,header:TimeStoreHeader(updated))
            } else {
                try JSONEncoder().encode(updated).write(to:fileURL,options:.atomic)
            }
            data=updated
            pendingFixes.removeAll(keepingCapacity:true)
            pendingIntervals.removeAll(keepingCapacity:true)
            pendingTotals.removeAll(keepingCapacity:true)
            lastSaved = .now
            return true
        } catch {
            gpsStatus="Error al descartar hueco: \(error.localizedDescription)"
            return false
        }
    }
    /// Restaura SOLO la sugerencia seleccionada. No cambia los intervalos.
    @discardableResult func restoreReviewedGap(_ gap:TimeGPSGapReview)->Bool {
        guard data.dismissedGPSGapIDs.contains(gap.id) else { return true }
        var updated=data
        updated.dismissedGPSGapIDs.removeAll { $0==gap.id }
        do {
            if let store {
                try store.append(fixes:pendingFixes,intervals:pendingIntervals,
                    totals:pendingTotals,header:TimeStoreHeader(updated))
            } else {
                try JSONEncoder().encode(updated).write(to:fileURL,options:.atomic)
            }
            data=updated
            pendingFixes.removeAll(keepingCapacity:true)
            pendingIntervals.removeAll(keepingCapacity:true)
            pendingTotals.removeAll(keepingCapacity:true)
            lastSaved = .now
            return true
        } catch {
            gpsStatus="No se pudo restaurar la sugerencia: \(error.localizedDescription)"
            return false
        }
    }
    func restoreDismissedGPSGaps() {
        data.dismissedGPSGapIDs=[]
        save(force:true)
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
        if previous == nil || retainedAge >= 120 || retainedDistance >= 16 || lastRetained?.cell != sample.cell {
            data.fixes.append(sample)
            pendingFixes.append(sample)
        }
        if stableCell != beforeStable ||
           delta > GPSHistoryGrouping.gapLimit || currentVisitStart == nil {
            let continued = previous == nil && restContinuationCell == stableCell ?
                restContinuationStart : nil
            currentVisitStart = continued ?? sample.date
            data.savedVisitStart = currentVisitStart
        }
        let sameRestCell = previous == nil && restContinuationCell == stableCell
        restContinuationStart = nil
        restContinuationCell = nil
        current = sample
        if let cell=stableCell {
            let continuedFromRest=sameRestCell
            updateZoneVisit(cell:cell,at:sample.date,
                             previousDate:previous?.date,
                             preserveRest:continuedFromRest)
        }
        if let stableCell,stableCell != beforeStable,
           location.horizontalAccuracy <= 45 {
            territoryAutoClassifier.enqueue(stableCell,model:self)
        }
        gpsStatus = "GPS activo · ±\(Int(sample.accuracy)) m"
        save(force: delta > GPSHistoryGrouping.gapLimit)
        activityPublisher.refresh(from:self)
        evaluateCurrentSite(now: sample.date)
        GPSPersonalAlerts.shared.evaluate(model:self)
        SiteStayNotifications.shared.evaluate(model:self)
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
        let manualRestIntervals = data.intervals.filter {
            $0.source=="descanso" || TimeRecoveryIndex.sources.contains($0.source)
        }
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
        // GPX reconstruye los intervalos de GPS, pero NO los periodos nocturnos
        // asumidos que fueron registrados explícitamente por el usuario.
        if !manualRestIntervals.isEmpty {
            data.intervals = (data.intervals + manualRestIntervals)
                .sorted { $0.start < $1.start }
            data.totals = TimeAttribution.byCell(data.intervals)
            pendingIntervals = data.intervals
            pendingTotals = data.totals
            normalizedCacheIntervalCount = -1
        }
        do {
            try store?.replaceAll(data)
            pendingFixes = []
            pendingIntervals = []
            pendingTotals = [:]
            lastProcessedSample = data.fixes.last
            stableCell = data.fixes.last?.cell
            save(force:true)
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
    func exportEncryptedBackup(password:String) throws -> URL {
        save(force:true)
        var snapshot=data
        // Una copia nocturna congela su fecha; restaurarla otro día nunca
        // puede multiplicar el tiempo asumido desde la antigua pausa.
        if let rest=snapshot.gpsRest {
            let now=Date()
            if now>rest.startedAt {
                let part=AssignedInterval(start:rest.startedAt,end:now,cell:rest.cell,
                        quality:"asumido · copia durante pausa",source:"descanso")
                snapshot.intervals.append(part)
                snapshot.totals[rest.cell.id,default:0] += now.timeIntervalSince(rest.startedAt)
            }
        }
        snapshot.gpsRest=nil
        snapshot.trackingEnabled=false
        snapshot.savedVisitStart=nil
        let data=try TimeSecureBackup.encrypt(snapshot,password:password)
        let stamp=Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(
            "MiMapaDelTiempo-\(stamp).mmapbak")
        try data.write(to:file,options:.atomic)
        return file
    }

    func inspectEncryptedBackup(_ bytes:Data,password:String) throws -> String {
        let restored=try TimeSecureBackup.decrypt(bytes,password:password)
        return "\(restored.fixes.count) posiciones, \(restored.intervals.count) intervalos, \(restored.customZones.count) zonas"
    }

    /// Restauración TOTAL únicamente con seguimiento apagado y confirmación.
    /// SQLite.replaceAll es transaccional, no deja media copia restaurada.
    func restoreEncryptedBackup(_ bytes:Data,password:String) throws {
        guard !recording && !isResting else {
            throw TimeBackupError.invalidBackup
        }
        var restored=try TimeSecureBackup.decrypt(bytes,password:password)
        restored.trackingEnabled=false
        restored.gpsRest=nil
        restored.savedVisitStart=nil
        guard !storageLoadFailed, let store else {
            throw TimeStoreError.sql("Almacenamiento no disponible; restauración bloqueada para proteger los datos")
        }
        // Do not overwrite a newer history with a backup during incident recovery.
        let existing = try store.load()
        guard existing.fixes.isEmpty && existing.intervals.isEmpty && existing.totals.isEmpty else {
            throw TimeStoreError.sql("La restauración reemplazaría el historial existente. Exporta y verifica ambas copias antes de continuar.")
        }
        try store.replaceAll(restored)
        data=restored
        currentZoneVisitID=nil
        currentZoneVisitStart=nil
        invalidateZoneCatalog()
        current=nil
        lastProcessedSample=restored.fixes.last
        stableCell=restored.fixes.last?.cell
        currentVisitStart=nil
        normalizedTotalsCache=[:]
        normalizedCacheIntervalCount = -1
        pendingFixes=[]; pendingIntervals=[]; pendingTotals=[:]
        gpsStatus="Historial restaurado · GPS detenido"
        activityPublisher.refresh(from:self,force:true)
    }

    func exportJSON() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mi-Mapa-del-Tiempo.json")
        try JSONEncoder().encode(data).write(to: url, options: .atomic)
        return url
    }
    func save(force: Bool = false) {
        guard !storageLoadFailed else {
            gpsStatus = "Almacenamiento sin cargar · datos protegidos · no guardar"
            return
        }
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
            // Consistent on-device backup at most once every six hours.
            // Keep tracking even if backup creation fails: the primary commit succeeded.
            if let store,
               Date().timeIntervalSince(lastSafetyCopyAttempt) >= 21_600,
               (!data.fixes.isEmpty || !data.intervals.isEmpty || !data.totals.isEmpty) {
                lastSafetyCopyAttempt = Date()
                // Separate SQLite connection and utility queue: backup I/O
                // never occupies the main thread, while WAL allows writes.
                // Do not pass the live store across actor/thread boundaries.
                let directory = fileURL.deletingLastPathComponent()
                let databaseURL = directory.appendingPathComponent("time-map-v3.sqlite")
                DispatchQueue.global(qos:.utility).async {
                    do {
                        let reader = try TimeSQLiteStore(url:databaseURL)
                        try reader.createSafetyCopy(in:directory)
                    } catch {
                        DispatchQueue.main.async {
                            self.storeStatus = "SQLite activo · copia de seguridad pendiente"
                        }
                    }
                }
            }
        } catch {
            storageLoadFailed = true
            storeStatus = "ERROR DE ALMACENAMIENTO · escrituras bloqueadas: \(error.localizedDescription)"
            gpsStatus = "Error guardando datos · almacenamiento protegido"
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
    private var lastReceivedAt: Date?
    weak var model: TimeModel?

    @Published private(set) var mode: GPSPowerMode = .precision
    @Published private(set) var movingSoon = false
    @Published private(set) var motionAvailable = CMMotionActivityManager.isActivityAvailable()
    @Published private(set) var pauseCount = 0
    @Published private(set) var resumeCount = 0
    @Published private(set) var lastGapSeconds: TimeInterval = 0
    @Published private(set) var lastCallbackAt: Date?
    @Published private(set) var automaticRestResumptions = 0
    @Published private(set) var lastPauseTransition = "Sin incidencias registradas"
    private var restTransitionInProgress = false

    override init() {
        super.init()
        manager.delegate = self
        configureContinuous()
    }

    /// Una única configuración para caminar, conducir y permanecer parado.
    /// CoreMotion informa, pero nunca reduce ni detiene el seguimiento.
    private func configureContinuous() {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = GPSContinuityPolicy.distanceFilter
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = GPSContinuityPolicy.pausesAutomatically
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    @MainActor func begin(_ model: TimeModel) {
        guard model.storageIsHealthy else {
            model.gpsStatus = "GPS detenido · almacenamiento no disponible"
            return
        }
        guard !restTransitionInProgress else { return }
        self.model = model
        if model.isResting {
            model.finishRest()
            automaticMonitoringStop()
        }
        lastPosition = nil
        lastReceivedAt = nil
        configureContinuous()
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
        GPSStaleWatchdog.shared.begin()
        if manager.authorizationStatus == .authorizedAlways {
            manager.startMonitoringSignificantLocationChanges()
        }
        motion.begin { [weak self] moving in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.motionMoving = moving
                if moving == true {
                    self.decision.motionStarted(at: Date())
                    self.movingSoon = self.decision.movingSoon
                }
            }
        }
        model.recording = true
        model.setTrackingEnabled(true)
        model.gpsStatus = "GPS continuo · buscando ubicación"
        model.recordPowerEvent(mode: .precision,
                               cause: "Inicio GPS continuo · sin pausa automática")
    }

    /// Pausa de precisión con seguimiento de salida de zona de bajo consumo.
    @MainActor func rest(_ model: TimeModel) {
        // Transición serial: protege frente a doble pulsación y cambios de
        // CoreLocation mientras el modelo se marca como pausado.
        guard !restTransitionInProgress,!model.isResting,model.recording else { return }
        restTransitionInProgress = true
        defer { restTransitionInProgress = false }
        self.model = model
        guard model.pauseForRest() else {
            lastPauseTransition = "Pausa no iniciada: se necesita GPS reciente"
            return
        }
        manager.stopUpdatingLocation()
        GPSStaleWatchdog.shared.cancel()
        motion.end()
        automaticMonitoringStart()
        lastPauseTransition = "Pausa activada y guardada · \(Date().formatted(date:.omitted,time:.shortened))"
        // No iniciar la presentación de ActivityKit en mitad de la transición
        // síncrona de SwiftUI/CoreLocation. Si ya se ha reanudado, ignorarla.
        Task { @MainActor [weak model] in
            guard let model,model.isResting else { return }
            model.refreshLive()
        }
    }

    @MainActor func restoreRest(_ model: TimeModel) {
        guard model.storageIsHealthy else {
            model.gpsStatus = "GPS detenido · almacenamiento no disponible"
            return
        }
        guard model.isResting else { return }
        self.model = model
        manager.stopUpdatingLocation()
        GPSStaleWatchdog.shared.cancel()
        motion.end()
        model.recording = false
        model.gpsStatus = "GPS en pausa · tiempo acumulándose en \(model.restingCellName ?? "cuadrícula")"
        automaticMonitoringStart()
    }

    @MainActor private func automaticMonitoringStart() {
        guard let rest = model?.data.gpsRest,
              manager.authorizationStatus == .authorizedAlways else { return }
        manager.startMonitoringSignificantLocationChanges()
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
              manager.maximumRegionMonitoringDistance > 0 else { return }
        let radius = min(GPSRestPolicy.geofenceRadius,
                         manager.maximumRegionMonitoringDistance)
        guard radius >= 100 else { return }
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: rest.latitude, longitude: rest.longitude),
            radius: radius, identifier: "mimapa-descanso")
        region.notifyOnEntry = false
        region.notifyOnExit = true
        for old in manager.monitoredRegions where old.identifier == region.identifier {
            manager.stopMonitoring(for: old)
        }
        manager.startMonitoring(for: region)
    }

    private func automaticMonitoringStop() {
        for region in manager.monitoredRegions where region.identifier == "mimapa-descanso" {
            manager.stopMonitoring(for: region)
        }
        manager.stopMonitoringSignificantLocationChanges()
    }

    @MainActor func haltForStorageFailure(_ model: TimeModel) {
        manager.stopUpdatingLocation()
        GPSStaleWatchdog.shared.cancel()
        automaticMonitoringStop()
        motion.end()
        model.recording = false
        model.gpsStatus = "GPS detenido · error de almacenamiento"
        movingSoon = false
        lastReceivedAt = nil
        lastPosition = nil
    }

    @MainActor func end(_ model: TimeModel) {
        if model.isResting { model.finishRest() }
        manager.stopUpdatingLocation()
        GPSStaleWatchdog.shared.cancel()
        automaticMonitoringStop()
        manager.stopMonitoringSignificantLocationChanges()
        motion.end()
        model.recording = false
        model.setTrackingEnabled(false)
        model.gpsStatus = "Detenido"
        model.recordPowerEvent(mode: .precision, cause: "Seguimiento detenido")
        model.save(force: true)
        movingSoon = false
        decision = SmartGPSDecision()
        lastReceivedAt = nil
        lastPosition = nil
    }

    private var lastOnDemandFixRequest = Date.distantPast

    @MainActor func requestFreshFixIfNeeded() {
        guard let model,model.recording,!model.isResting,
              manager.authorizationStatus == .authorizedAlways ||
              manager.authorizationStatus == .authorizedWhenInUse else { return }
        let now=Date()
        let age=now.timeIntervalSince(model.current?.date ?? .distantPast)
        guard age >= 5,now.timeIntervalSince(lastOnDemandFixRequest) >= 4 else { return }
        lastOnDemandFixRequest=now
        // Uses the EXISTING CLLocationManager; no second GPS session or
        // expensive configuration on the navigation gesture.
        manager.requestLocation()
    }

    @MainActor func refreshWhenForeground() {
        guard let model,model.recording,!model.isResting,
              manager.authorizationStatus == .authorizedAlways ||
              manager.authorizationStatus == .authorizedWhenInUse else { return }
        configureContinuous()
        manager.startUpdatingLocation()
        requestFreshFixIfNeeded()
        GPSStaleWatchdog.shared.refresh(recording:model.recording,
            resting:model.isResting,latestFix:model.current?.date)
    }

    @MainActor func setAnticipation(_ enabled: Bool) {
        if enabled { decision.anticipate() }
        else { decision.cancelAnticipation() }
        movingSoon = decision.movingSoon
        // Compatibilidad con el control anterior. No cambia el servicio GPS.
    }

    @MainActor private func observe(_ location: CLLocation) {
        let distance = lastPosition.map { $0.distance(from: location) } ?? 0
        lastPosition = location
        decision.observe(date: location.timestamp,
                         speed: max(0, location.speed),
                         metersSincePrevious: distance,
                         motionMoving: motionMoving)
        movingSoon = decision.movingSoon
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
                guard location.horizontalAccuracy >= 0,
                      location.timestamp <= Date().addingTimeInterval(5) else { continue }
                // Durante el descanso los eventos de localización de bajo consumo
                // solo sirven para solicitar GPS si la salida está suficientemente lejos.
                if let rest = model?.data.gpsRest {
                    guard location.timestamp >= rest.startedAt else { continue }
                    let anchor = CLLocation(latitude:rest.latitude,longitude:rest.longitude)
                    if GPSRestPolicy.shouldResume(distance:anchor.distance(from:location),
                                                  accuracy:location.horizontalAccuracy),
                       let model {
                        automaticRestResumptions += 1
                        begin(model)
                        model.recordPowerEvent(mode:.precision,
                            cause:"GPS reactivado al detectar desplazamiento fuera de la zona")
                    } else { continue }
                }
                // No registrar de nuevo muestras antiguas tras un despertar.
                guard lastReceivedAt.map({ location.timestamp > $0 }) ?? true else { continue }
                if let gap = GPSContinuityPolicy.observedGap(
                    after:lastReceivedAt ?? model?.lastGPSFix,
                    at:location.timestamp) {
                    lastGapSeconds = gap
                    if gap >= 60 {
                        model?.recordPowerEvent(mode: .precision,
                            cause: "Hueco GPS observado: \(Int(gap)) segundos; no se reconstruye")
                    }
                }
                lastReceivedAt = location.timestamp
                lastCallbackAt = Date()
                model?.record(location)
                if model?.recording == true, model?.isResting == false {
                    GPSStaleWatchdog.shared.received(location.timestamp)
                }
                observe(location)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            guard region.identifier == "mimapa-descanso",
                  let model, model.isResting,
                  let rest = model.data.gpsRest,
                  let observed = region as? CLCircularRegion else { return }
            let anchor = CLLocation(latitude:rest.latitude,longitude:rest.longitude)
            let monitored = CLLocation(latitude:observed.center.latitude,
                                       longitude:observed.center.longitude)
            guard anchor.distance(from:monitored) < 5 else { return }
            automaticRestResumptions += 1
            begin(model)
            model.recordPowerEvent(mode:.precision,
                cause:"GPS reactivado tras aviso de salida de la zona de descanso")
        }
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            pauseCount += 1
            model?.recordPowerEvent(mode: .precision,
                cause: "CoreLocation notificó pausa inesperada; solicitando reanudación")
            guard model?.recording == true else { return }
            configureContinuous()
            manager.startUpdatingLocation()
        }
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            resumeCount += 1
            model?.recordPowerEvent(mode: .precision, cause: "CoreLocation notificó reanudación")
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            model?.gpsStatus = "GPS: \(error.localizedDescription)"
            if let failure = error as? CLError, failure.code == .locationUnknown { return }
            model?.recordPowerEvent(mode: .precision,
                                    cause: "Error GPS: \(error.localizedDescription)")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                model?.gpsStatus = "Permiso GPS denegado"
                model?.recordPowerEvent(mode: .precision, cause: "Autorización GPS denegada")
            } else if manager.authorizationStatus == .authorizedAlways,
                      model?.isResting == true {
                automaticMonitoringStart()
            } else if manager.authorizationStatus == .authorizedAlways, model?.recording == true {
                manager.startMonitoringSignificantLocationChanges()
                configureContinuous()
                manager.startUpdatingLocation()
            }
        }
    }
}
@main struct MiMapaDelTiempoApp: App {
    // Register the notification action delegate at launch, including launches
    // triggered by the background Confirmado action.
    init() { _ = SiteStayNotifications.shared }

    @StateObject private var model = TimeModel()
    @StateObject private var gps = GPSService()
    @Environment(\.scenePhase) private var phase
    @State private var resumeTask: Task<Void,Never>?
    var body: some Scene {
        WindowGroup {
            RootView(model: model, gps: gps)
                .environment(\.locale, Locale(identifier:"es_ES"))
                .onAppear {
                    // Se reactiva al volver a abrir la app, respetando la opción previa.
                    if model.isResting { gps.restoreRest(model) }
                    else if model.data.trackingEnabled && !model.recording { gps.begin(model) }
                    model.restoreLiveActivityIfNeeded()
                    SiteStayNotifications.shared.activate(model: model)
                }
                .onChange(of: model.storageIsHealthy) { _, healthy in
                    if !healthy { gps.haltForStorageFailure(model) }
                }
                .onChange(of: phase) { _, state in
                    resumeTask?.cancel()
                    if state != .active {
                        // Keep the durable iOS background commit. A delayed
                        // write could be suspended before finishing.
                        model.save(force:true)
                    } else {
                        // Render the restored SwiftUI frame FIRST. Returning
                        // from another app should never synchronously run
                        // location reconfiguration and ActivityKit updates
                        // on the same UI/navigation frame.
                        GPSStaleWatchdog.shared.refresh(recording:model.recording,
                            resting:model.isResting,latestFix:model.current?.date)
                        resumeTask=Task { @MainActor in
                            try? await Task.sleep(for:.milliseconds(250))
                            guard !Task.isCancelled else { return }
                            gps.refreshWhenForeground()
                            // Allow GPS to resume; activity refresh is secondary.
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            model.restoreLiveActivityIfNeeded()
                        }
                    }
                }
        }
    }
}
/// Compact six-tab bar designed for iPhone portrait. All six destinations
/// remain one tap away; unlike the stock TabView no tab is hidden in "Más".
private struct TimeSixTabBar: View {
    @Binding var selectedTab: Int

    private struct Entry: Identifiable {
        let id: Int
        let title: String
        let icon: String
    }
    private let tabs: [Entry] = [
        Entry(id: 0, title: "Mapa", icon: "map"),
        Entry(id: 1, title: "Estad.", icon: "chart.bar.fill"),
        Entry(id: 2, title: "Histórico", icon: "clock.arrow.circlepath"),
        Entry(id: 5, title: "Descubrir", icon: "globe.europe.africa.fill"),
        Entry(id: 3, title: "Sitios", icon: "mappin.circle.fill"),
        Entry(id: 4, title: "Ajustes", icon: "gearshape")
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(tabs) { tab in
                let active = selectedTab == tab.id
                Button {
                    selectedTab = tab.id
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: active ? .semibold : .regular))
                            .frame(height: 24)
                        Text(tab.title)
                            .font(.system(size: 10, weight: active ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(active ? Color.teal : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 49)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title == "Estad." ? "Estadísticas" : tab.title)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
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
    private func openGPSGapHistoryIfRequested() {
        guard UserDefaults.standard.bool(forKey:"gpsWatchdogOpenHistory") else { return }
        UserDefaults.standard.removeObject(forKey:"gpsWatchdogOpenHistory")
        model.selectedTab=2
    }
    var body: some View {
        ZStack {
            // The custom six-tab bar must take REAL layout height, not be
            // painted over a NavigationStack/List through safeAreaInset.
            // A vertical stack guarantees pushed detail screens end above
            // the bar, including after an interactive scroll stops.
            VStack(spacing: 0) {
                selectedScreen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TimeSixTabBar(selectedTab: $model.selectedTab)
            }
                .tint(.teal)
                .onAppear { openGPSGapHistoryIfRequested() }
            .onReceive(NotificationCenter.default.publisher(
                for:Notification.Name("gpsWatchdogOpenHistory"))) { _ in
                openGPSGapHistoryIfRequested()
            }
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
        .onAppear { unlocked = !faceIDEnabled; if faceIDEnabled { checkFaceID() }; model.discardUnsupportedAutomaticSiteAssignments(); model.refreshLive() }
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
    // Six real, directly visible tabs. Native iOS TabView moves the sixth
    // into "Más"; the lightweight local bar avoids hiding Descubrir or Sitios.
    // TimeModel owns GPS, history, BIOGRID and Live Activity independently.
    @ViewBuilder private var selectedScreen: some View {
        switch model.selectedTab {
        case 0:
            TimeMapView(model: model, gps: gps)
        case 1:
            TimeStatsDashboard(model: model)
        case 2:
            GPSDiaryShell(model: model)
        case 3:
            NavigationStack { TimeSiteCalendarView(model: model) }
        case 4:
            TimeSettingsView(model: model, gps: gps)
        case 5:
            NavigationStack { TimeDiscoveryHome(model: model) }
        default:
            TimeMapView(model: model, gps: gps)
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
private struct MapCellRender: Identifiable {
    let cell:Cell
    let seconds:TimeInterval
    var id:String { cell.id }
}
struct TimeMapView: View {
    @ObservedObject var model: TimeModel
    @ObservedObject var gps: GPSService
    @StateObject private var connectivity = MapConnectivity()
    // Start at the saved viewport; avoid MapKit's automatic camera followed
    // by an immediate recenter, which can flash empty map tiles on launch.
    @State private var camera: MapCameraPosition
    @State private var region: MKCoordinateRegion
    @State private var namingCell: Cell?
    @State private var historyCell: Cell?
    @State private var inspectedZone: TimeCustomZone?
    @State private var expandedZoneLabelID: UUID?
    @State private var searchOpen = false
    @State private var queuedCellForMap: Cell?
    @State private var followLocation:Bool
    // Presentación local: nunca se persiste ni altera los intervalos GPS.
    @State private var cardSize: TimeMapCardSize = .compact
    @State private var cardBeforeDragging: TimeMapCardSize?
    @State private var restoredCamera = false
    // Drawing snapshot only; full GPS history remains stored unmodified.
    @State private var renderedRouteSegments: [[CLLocationCoordinate2D]] = []
    // Keep drawing geometry stable while MapKit handles pinch and pan gestures.
    // Rebuild the viewport snapshot only after a camera movement settles.
    @State private var renderedCells: [MapCellRender] = []
    @State private var renderedZones: [TimeZoneOverlay] = []
    @State private var renderedMaximumTime: TimeInterval = 1
    @State private var renderedRegion: MKCoordinateRegion?
    @State private var renderedPeriod: TimePeriod?
    @State private var renderedIntervalCount = -1
    @State private var renderedGridCount = -1
    @State private var renderedAt = Date.distantPast
    @State private var deferredCameraSave: Task<Void, Never>?
    @State private var renderedRouteFixCount = -1
    @State private var renderedRoutePeriod = ""
    @State private var lastRouteDraw = Date.distantPast
    @State private var routeRenderGeneration = UUID()
    @Environment(\.scenePhase) private var scenePhase

    init(model: TimeModel, gps: GPSService) {
        self.model = model
        self.gps = gps
        let saved = model.data.camera.region
        _camera = State(initialValue: .region(saved))
        _region = State(initialValue: saved)
        _followLocation = State(initialValue: model.mapFollowLocation)
    }

    func paint(_ sec: TimeInterval, maximum: TimeInterval) -> Color {
        if model.explore { return .cyan }
        if model.adaptive {
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
    var body: some View { mapLifecycle }

    private var mapSheets: some View {
        ZStack(alignment: .bottom) {
            mapLayers
            mapControls
        }
        .sheet(item:$inspectedZone) { zone in
            TimeMapZoneSummary(model:model,zone:zone) { cell in
                followLocation=false
                model.selected=cell
                let target=MKCoordinateRegion(center:Grid.center(cell),span:region.span)
                region=target
                refreshMapSnapshot(force: true)
                camera = .region(target)
                queueCameraSave(target)
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
    }

    // Keep SwiftUI modifier chains short for predictable type checking.
    // Dividing the event handlers does not alter their execution or order.
    private var mapBaseDataEvents: some View {
        mapSheets
        .onChange(of:searchOpen) { _,open in
            if !open,let cell=queuedCellForMap {
                queuedCellForMap=nil
                model.navigate(to:cell)
            }
        }
        .onChange(of:model.period) { _,_ in refreshMapSnapshot(force: true) }
        // Lightweight periodic refresh also catches midnight while GPS is
        // voluntarily paused and no new location events arrive.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            guard model.selectedTab == 0 else { return }
            model.evaluateCurrentSite()
            refreshMapSnapshot()
        }
        .onChange(of:model.data.intervals.count) { _,_ in refreshMapSnapshot() }
        .onChange(of:model.data.totals.count) { _,_ in refreshMapSnapshot() }
    }

    private var mapDataEvents: some View {
        mapBaseDataEvents
        .onChange(of:model.totalsRefreshRevision) { _,_ in
            refreshMapSnapshot(force:true)
        }
        .onChange(of:model.zoneOverlayRevision) { _,_ in
            refreshMapSnapshot(force:true)
        }
        .onChange(of:model.data.customZones.count) { _,_ in refreshMapSnapshot(force: true) }
        .onChange(of:model.data.places.count) { _,_ in refreshMapSnapshot(force: true) }
        .onChange(of:namingCell) { _,newValue in
            if newValue == nil { refreshMapSnapshot(force: true) }
        }
    }

    private var mapRouteEvents: some View {
        mapDataEvents
        .onChange(of:model.routePeriod) { _,_ in refreshRenderedRoutes(force: true) }
        .onChange(of:model.showRoutes) { _,_ in refreshRenderedRoutes(force: true) }
        .onChange(of:model.selectedTab) { _,tab in
            if tab == 0 {
                refreshRenderedRoutes()
                gps.requestFreshFixIfNeeded()
            }
        }
        .onChange(of:followLocation) { _, enabled in
            model.mapFollowLocation = enabled
        }
        .onChange(of:model.current?.date) { _,_ in
            refreshRenderedRoutes()
            refreshMapSnapshot()
            if followLocation {
                model.selected=nil
                focusOnCurrentLocation()
            }
        }
        .onChange(of:model.activeCell?.id) { _,_ in
            refreshMapSnapshot(force: true)
            if followLocation { model.selected=nil }
        }
    }

    private var mapLifecycle: some View {
        mapRouteEvents
        .onChange(of:scenePhase) { _,phase in
            if phase == .active {
                // App scene owns GPS/ActivityKit restoration. Repeating it
                // synchronously inside the map caused foreground UI stalls.
                if followLocation { focusOnCurrentLocation() }
            }
        }
        .onAppear {
            // First paint may use a stored position; request a fresh GPS fix
            // without reinitializing CoreLocation or blocking navigation.
            refreshRenderedRoutes()
            refreshMapSnapshot(force:true)
            Task { @MainActor in
                await Task.yield()
                gps.requestFreshFixIfNeeded()
                if followLocation { focusOnCurrentLocation() }
            }
        }
        .onDisappear {
            deferredCameraSave?.cancel()
            // Preserve the user's last viewpoint when leaving the map.
            model.updateCamera(region)
        }
    }

    /// Map rendering is isolated from overlay buttons and the 1-second clock.
    private var mapLayers: some View {
        let visibleCells = renderedCells
        let visibleZones = renderedZones
        let focusZoneID = (followLocation ? model.activeCell :
            (model.selected ?? model.activeCell)).flatMap {
                model.primaryZone(for: $0)?.id
            }
        let visibleZoneLabelIDs = TimeZoneLabelLayout.visibleIDs(
            visibleZones, viewport: region, preferredZoneID: focusZoneID)
        let maximumVisibleTime = renderedMaximumTime
        let useBasicMap = model.forceBasicMap || !connectivity.connected
        return ZStack {
            MapReader { proxy in
                Map(position: $camera) {
                    ForEach(visibleCells) { item in
                        MapPolygon(coordinates: Grid.polygon(item.cell))
                            .foregroundStyle(paint(item.seconds,maximum:maximumVisibleTime).opacity(model.cellFillOpacity))
                            .stroke(.white.opacity(0.85), lineWidth: 1)
                    }
                    // Limit only the text overlays, never the visited coloured squares.
                    // Large quantities of text annotations severely slow MapKit gestures.
                    if region.span.latitudeDelta < 0.010 {
                        ForEach(visibleCells.prefix(80)) { item in
                            Annotation("", coordinate: Grid.center(item.cell), anchor: .center) {
                                Text(DurationFormat.small(item.seconds))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(2)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    ForEach(visibleZones) { overlay in
                        ForEach(overlay.contours) { line in
                            MapPolyline(coordinates:line.coordinates)
                                .stroke(overlay.zone.id ==
                                    (followLocation ? model.activeCell : (model.selected ?? model.activeCell))
                                        .flatMap { model.primaryZone(for:$0) }?.id
                                        ? Color.teal : Color.teal.opacity(0.6),
                                        lineWidth:overlay.zone.id ==
                                    (followLocation ? model.activeCell : (model.selected ?? model.activeCell))
                                        .flatMap { model.primaryZone(for:$0) }?.id ? 5 : 2.5)
                        }
                        if region.span.latitudeDelta < 0.07,
                           visibleZoneLabelIDs.contains(overlay.id),
                           let center=overlay.center {
                            Annotation("",coordinate:center) {
                                Button {
                                    followLocation=false
                                    if expandedZoneLabelID == overlay.zone.id {
                                        // Second tap keeps the existing Zone Details
                                        // functionality available.
                                        inspectedZone=overlay.zone
                                    } else {
                                        withAnimation(.easeOut(duration:0.17)) {
                                            expandedZoneLabelID=overlay.zone.id
                                        }
                                    }
                                } label: {
                                    if expandedZoneLabelID == overlay.zone.id {
                                        VStack(spacing:3) {
                                            Text(overlay.zone.name)
                                                .font(.system(size:11,weight:.semibold))
                                                .multilineTextAlignment(.center)
                                                .fixedSize(horizontal:false,vertical:true)
                                            Text("Toca para ver detalles")
                                                .font(.system(size:8))
                                                .opacity(0.85)
                                        }
                                        .frame(maxWidth:168)
                                        .padding(.horizontal,8)
                                        .padding(.vertical,6)
                                        .foregroundStyle(.white)
                                        .background(Color.teal.opacity(0.94),in:RoundedRectangle(cornerRadius:9))
                                    } else {
                                        Text(TimeZoneLabelText.initials(overlay.zone.name))
                                            .font(.system(size:8,weight:.semibold))
                                            .lineLimit(1)
                                            .padding(.horizontal,4)
                                            .padding(.vertical,3)
                                            .foregroundStyle(.white)
                                            .background(Color.teal.opacity(0.91),in:RoundedRectangle(cornerRadius:5))
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(expandedZoneLabelID == overlay.zone.id ?
                                    "Ver detalles de zona \(overlay.zone.name)" :
                                    "Expandir nombre de zona \(overlay.zone.name)")
                            }
                        }
                    }
                    // Delimitación de la casilla que muestra la tabla, por encima
                    // de los perímetros de zona. Naranja = actual, violeta = consultada.
                    if let focusedCell = followLocation ? model.activeCell :
                        (model.selected ?? model.activeCell) {
                        let viewingAnotherCell = focusedCell != model.activeCell
                        MapPolygon(coordinates:Grid.polygon(focusedCell))
                            .foregroundStyle((viewingAnotherCell ? Color.indigo : Color.orange).opacity(0.09))
                            .stroke(viewingAnotherCell ? Color.indigo : Color.orange,lineWidth:4)
                    }
                    if let position = model.current {
                        Annotation("Actual", coordinate: position.coordinate) {
                            Circle().fill(.blue).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                    }
                    if model.showRoutes {
                        ForEach(renderedRouteSegments.indices, id: \.self) { index in
                            MapPolyline(coordinates: renderedRouteSegments[index])
                                .stroke(.blue, lineWidth: 3)
                        }
                    }
                }
                .mapStyle(model.mapKind == .satellite ? .imagery : model.mapKind == .hybrid ? .hybrid : .standard)
                .onTapGesture { point in
                    if let coord = proxy.convert(point, from: .local) {
                        let touched=Grid.cell(latitude:coord.latitude,longitude:coord.longitude)
                        selectOnMap(touched)
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { ctx in
                    // Suppress MapKit's own tiny startup/camera corrections:
                    // they are not user moves and must not rewrite the viewport.
                    guard !useBasicMap,
                          MapViewportPolicy.meaningfulChange(from: region, to: ctx.region) else { return }
                    region = ctx.region
                    // Camera updates also arrive from our own GPS recentering
                    // and zoom buttons; those must keep follow mode enabled.
                    if followLocation && camera.positionedByUser {
                        followLocation = false
                    }
                    refreshMapSnapshot(force: true)
                    queueCameraSave(ctx.region)
                    // Camera events no longer serialize the full GPS history
                    // while the user is still manipulating MapKit.
                }
                .onAppear { centerOnRequestedCell(); refreshMapSnapshot(force: true) }
                .onChange(of:model.mapNavigationRevision) { _,_ in centerOnRequestedCell() }
            }
            .opacity(useBasicMap ? 0 : 1)
            .allowsHitTesting(!useBasicMap)
            if useBasicMap {
                OfflineGridMap(model:model,region:$region,onNavigate:{ newRegion in
                    followLocation = false
                    model.updateCamera(newRegion)
                    camera = .region(newRegion)
                },onSelect:{ cell in
                    selectOnMap(cell)
                },onInteractionStart:{
                    beginMapDrag()
                },onInteractionEnd:{
                    endMapDrag()
                })
                .onAppear { centerOnRequestedCell(); refreshMapSnapshot(force: true) }
                .onChange(of:model.mapNavigationRevision) { _,_ in centerOnRequestedCell() }
            }
        }
    }

    private var mapControls: some View {
            VStack(spacing:4) {
                HStack(spacing:4) {
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
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .padding(.horizontal,7)
                            .frame(height:44)
                            .background(Color(.secondarySystemBackground).opacity(0.9),in:Capsule())
                    }
                    .accessibilityIdentifier("mapModeMenu")
                    Spacer(minLength:1)
                    Button { zoomMap(factor:0.6) } label: {
                        Image(systemName:"plus").font(.headline)
                            .frame(width:42,height:44)
                            .background(Color(.secondarySystemBackground).opacity(0.9),
                                        in:RoundedRectangle(cornerRadius:10))
                    }
                    .accessibilityLabel("Acercar mapa")
                    .accessibilityIdentifier("mapZoomIn")
                    Button { zoomMap(factor:1.65) } label: {
                        Image(systemName:"minus").font(.headline)
                            .frame(width:42,height:44)
                            .background(Color(.secondarySystemBackground).opacity(0.9),
                                        in:RoundedRectangle(cornerRadius:10))
                    }
                    .accessibilityLabel("Alejar mapa")
                    .accessibilityIdentifier("mapZoomOut")
                    Button { searchOpen=true } label: {
                        Image(systemName:"magnifyingglass").font(.headline)
                            .frame(width:42,height:44)
                            .background(Color(.secondarySystemBackground).opacity(0.9),
                                        in:RoundedRectangle(cornerRadius:10))
                    }
                    .accessibilityLabel("Buscar zonas y cuadrículas")
                    Button {
                        followLocation.toggle()
                        if followLocation {
                            model.selected=nil
                            focusOnCurrentLocation() // conserva exactamente el zoom actual
                            gps.refreshWhenForeground()
                        } else {
                            camera = .region(region)
                        }
                    } label: {
                        Image(systemName:followLocation ? "location.north.line.fill" : "location")
                            .foregroundStyle(followLocation ? Color.white : Color.primary)
                            .font(.headline)
                            .frame(width:42,height:44)
                            .background(followLocation ? Color.teal : Color(.secondarySystemBackground).opacity(0.9),
                                        in:RoundedRectangle(cornerRadius:10))
                    }
                    .accessibilityLabel(followLocation ? "Seguimiento activo; pasar a mapa libre" : "Mapa libre; seguir mi posición")
                }
                .buttonStyle(.plain)
                .padding(.horizontal,7)
                .padding(.vertical,4)
                .frame(maxWidth:.infinity)
                // Toda la franja, incluso los huecos, pertenece a los controles:
                // los toques y arrastres no pasan al mapa situado debajo.
                .background {
                    RoundedRectangle(cornerRadius:13)
                        .fill(.regularMaterial)
                        .contentShape(Rectangle())
                        .onTapGesture { }
                        .gesture(DragGesture(minimumDistance:0).onChanged { _ in })
                }
                .padding(.horizontal,8)
                .padding(.top,4)
                TimelineView(.periodic(from:.now,by:20)) { context in
                    let health=GPSHealthAssessment.evaluate(
                        recording:model.recording,
                        resting:model.isResting,
                        lastFix:model.current?.date,
                        now:context.date)
                    HStack(spacing:6) {
                        Image(systemName:health.symbol)
                            .foregroundStyle(health.needsAttention ? Color.orange : Color.teal)
                        Text(health.message)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength:0)
                        if health.needsAttention && model.recording {
                            Button("Actualizar") {
                                gps.refreshWhenForeground()
                            }
                            .font(.system(size:10,weight:.semibold))
                            .accessibilityLabel("Actualizar posición GPS")
                        }
                    }
                    .font(.system(size:11,weight:.medium))
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(.horizontal,9)
                    .frame(height:26)
                    .background(.regularMaterial,in:Capsule())
                    .padding(.horizontal,8)
                }
                // Los lugares se forman exclusivamente nombrando cuadrículas.
                HStack(spacing:4) {
                    ForEach(TimePeriod.allCases) { p in
                        Button(p.title) { model.period = p }
                            .font(.caption2.weight(model.period == p ? .bold : .medium))
                            .padding(.horizontal,9).padding(.vertical,5)
                            .background(model.period == p ? Color.teal.opacity(0.86) :
                                        Color(.secondarySystemBackground).opacity(0.92),in:Capsule())
                            .foregroundStyle(model.period == p ? Color.white : Color.primary)
                    }
                    Spacer(minLength:0)
                }.padding(.horizontal,8)
                if followLocation {
                    Text("Siguiéndome · toca la flecha para explorar libremente")
                        .font(.system(size:10))
                        .lineLimit(1)
                        .padding(.horizontal,10)
                }
                Spacer(minLength:0)
                VStack(alignment:.leading,spacing:8) {
                    let picked = followLocation ? model.activeCell :
                        (model.selected ?? model.activeCell)
                    let zone = picked.flatMap { model.primaryZone(for:$0) }
                    let isConsulting = picked != nil && picked != model.activeCell
                    HStack(alignment:.center,spacing:8) {
                        VStack(alignment:.leading,spacing:2) {
                            Text(zone?.name ?? picked.map { model.label(for:$0) } ?? "Sin cuadrícula actual")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Label((isConsulting ? "Consultando otra cuadrícula" :
                                    (picked == nil ? "Sin ubicación" : "Ubicación actual")) +
                                  " · " + model.period.title,
                                  systemImage:isConsulting ? "hand.tap" : "location.fill")
                                .font(.system(size:10,weight:.medium))
                                .foregroundStyle(isConsulting ? Color.indigo : Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength:4)
                        if cardSize == .minimized {
                            TimeMapMiniClock(model:model,picked:picked)
                        }
                        // Only compact and minimized modes remain available.
                        // Compact already shows total, current stay and visits.
                        Button {
                            withAnimation(.easeOut(duration:0.18)) {
                                cardSize = cardSize == .minimized ? .compact : .minimized
                            }
                        } label: {
                            Image(systemName:cardSize == .minimized ?
                                  "chevron.up" : "minus.circle")
                                .font(.system(size:17,weight:.semibold))
                        }
                        .accessibilityLabel(cardSize == .minimized ?
                            "Mostrar resumen con tiempo y visitas" : "Minimizar tarjeta")
                    }
                    .buttonStyle(.plain)
                    if cardSize != .minimized {
                        TimeMapCardContents(model:model,picked:picked,mode:cardSize)
                        if let cell=picked,cell == model.activeCell {
                            TimeSiteInlineView(model:model,cell:cell)
                                .padding(.top,4)
                        }
                        if let cell=picked {
                            HStack(spacing:18) {
                                Button("Histórico") { historyCell=cell }
                                Button("Nombre") { namingCell=cell }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .padding(.top,2)
                        }
                    }
                }
                .padding(cardSize == .minimized ? 10 : 12)
                .background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
                .padding(.horizontal,12)
                .padding(.bottom,8)
            }
    }
    /// A viewport-indexed snapshot avoids scanning and rebuilding thousands
    /// of map overlays every time the GPS or the card clock publishes a change.
    private func refreshMapSnapshot(force: Bool = false) {
        let now = Date()
        let intervalCount = model.data.intervals.count
        let gridCount = model.data.totals.count
        let samePeriod = renderedPeriod == model.period
        let sameData = renderedIntervalCount == intervalCount &&
                       renderedGridCount == gridCount
        let sameViewport = renderedRegion.map {
            !MapViewportPolicy.meaningfulChange(from: $0, to: region)
        } ?? false
        if !force && samePeriod && sameData && sameViewport &&
           now.timeIntervalSince(renderedAt) < 20 { return }

        let totals = model.periodTotals(now: now)
        let active = model.activeCell
        let activeExtra = active.map { model.provisionalSeconds(for: [$0.id], now: now) } ?? 0
        let north = min(85, region.center.latitude + region.span.latitudeDelta * 1.15)
        let south = max(-85, region.center.latitude - region.span.latitudeDelta * 1.15)
        let west = max(-179.999, region.center.longitude - region.span.longitudeDelta * 1.15)
        let east = min(179.999, region.center.longitude + region.span.longitudeDelta * 1.15)
        let first = Grid.cell(latitude: south, longitude: west).row
        let last = Grid.cell(latitude: north, longitude: east).row
        var candidateCells: [Cell] = []
        // At high zoom, enumerate only screen-adjacent 100 m squares.
        // At broad zoom, prefer confirmed stored cells over a giant empty grid.
        var gridIndexComplete = false
        if first <= last && last - first < 120 && region.span.longitudeDelta < 0.12 {
            gridIndexComplete = true
            for row in first...last {
                let latitude = -90 + (Double(row) + 0.5) * Grid.latitudeStep
                let minColumn = Grid.cell(latitude: latitude, longitude: west).column
                let maxColumn = Grid.cell(latitude: latitude, longitude: east).column
                guard minColumn <= maxColumn && maxColumn - minColumn <= 120 else {
                    gridIndexComplete = false
                    break
                }
                for column in minColumn...maxColumn {
                    candidateCells.append(Cell(row: row, column: column))
                }
            }
        }
        if !gridIndexComplete {
            // Never show only some visited cells when the viewport crosses
            // the indexing limit: scan saved cells instead, without truncation.
            candidateCells = model.allCells
        }
        if let active, !candidateCells.contains(active) {
            candidateCells.append(active)
        }
        var items: [MapCellRender] = []
        for cell in candidateCells {
            let secs = (totals[cell.id] ?? 0) + (cell == active ? activeExtra : 0)
            guard secs > 0 else { continue }
            let point = Grid.center(cell)
            guard abs(point.latitude - region.center.latitude) < region.span.latitudeDelta * 1.1 &&
                  abs(point.longitude - region.center.longitude) < region.span.longitudeDelta * 1.1 else { continue }
            items.append(MapCellRender(cell: cell, seconds: secs))
            if items.count >= 2000 { break }
        }
        // Assign stable arrays only at the end of computation.
        renderedMaximumTime = max(1, items.map(\.seconds).max() ?? 1)
        renderedCells = items
        renderedZones = model.zoneOverlays.filter { overlay in
            guard let point = overlay.center else { return false }
            return abs(point.latitude - region.center.latitude) < region.span.latitudeDelta * 1.8 &&
                   abs(point.longitude - region.center.longitude) < region.span.longitudeDelta * 1.8
        }
        renderedRegion = region
        renderedPeriod = model.period
        renderedIntervalCount = intervalCount
        renderedGridCount = gridCount
        renderedAt = now
    }

    /// Debounce viewport persistence: save() serializes the GPS history.
    /// Saving synchronously on every pinch/pan completion stalls the map.
    private func queueCameraSave(_ target: MKCoordinateRegion) {
        deferredCameraSave?.cancel()
        deferredCameraSave = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 900_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            model.updateCamera(target)
        }
    }

    /// Rebuild path geometry only for new fixes or an explicit route selection,
    /// never on every UI refresh, zoom gesture, or clock tick.
    private func refreshRenderedRoutes(force: Bool = false) {
        guard model.showRoutes else {
            if !renderedRouteSegments.isEmpty { renderedRouteSegments = [] }
            renderedRouteFixCount = -1
            return
        }
        let now = Date()
        let count = model.data.fixes.count
        let period = model.routePeriod.rawValue
        if !force {
            guard model.selectedTab == 0 else { return }
            guard count != renderedRouteFixCount ||
                  period != renderedRoutePeriod ||
                  now.timeIntervalSince(lastRouteDraw) >= 60 else { return }
            guard now.timeIntervalSince(lastRouteDraw) >= 5 else { return }
        }
        let generation = UUID()
        routeRenderGeneration = generation
        // Snapshot current route on main, but sort/split/map the thousands
        // of points on a lower-priority queue while gestures stay responsive.
        let points = model.routePoints(at: now)
        renderedRouteFixCount = count
        renderedRoutePeriod = period
        lastRouteDraw = now
        DispatchQueue.global(qos:.utility).async {
            let segments = GPSRouteSegments.split(points.map {
                GPSHistoryFix(date:$0.date,latitude:$0.latitude,longitude:$0.longitude)
            }).map { group in
                group.map { CLLocationCoordinate2D(latitude:$0.latitude,
                                                   longitude:$0.longitude) }
            }
            DispatchQueue.main.async {
                guard routeRenderGeneration == generation else { return }
                renderedRouteSegments = segments
            }
        }
    }

    private func beginMapDrag() {
        guard cardBeforeDragging == nil else { return }
        cardBeforeDragging=cardSize
        if cardSize != .minimized {
            withAnimation(.easeOut(duration:0.12)) { cardSize = .minimized }
        }
    }
    private func endMapDrag() {
        guard let previous=cardBeforeDragging else { return }
        cardBeforeDragging=nil
        withAnimation(.easeOut(duration:0.22)) { cardSize = previous }
    }
    private func selectOnMap(_ cell:Cell) {
        endMapDrag()
        followLocation=false
        model.selected=cell
        if let zone=model.primaryZone(for:cell) {
            inspectedZone=zone
        }
    }
    private func zoomMap(factor:Double) {
        let center=followLocation ? (model.current?.coordinate ?? region.center) : region.center
        let target=MapZoomPolicy.scaled(region,factor:factor,center:center)
        region=target
        refreshMapSnapshot(force: true)
        withAnimation(.easeOut(duration:0.18)) { camera = .region(target) }
        queueCameraSave(target)
    }
    private func focusOnCurrentLocation() {
        guard let position=model.current else { return }
        let target=MKCoordinateRegion(center:position.coordinate,span:region.span)
        region=target
        refreshMapSnapshot(force: true)
        withAnimation(.easeInOut(duration:0.24)) {
            camera = .region(target)
        }
    }
    private func centerOnRequestedCell() {
        if let c = model.takeMapTarget() {
            restoredCamera = true
            followLocation=false
            let center=Grid.center(c)
            let target=MKCoordinateRegion(center:center,
                   span:MKCoordinateSpan(latitudeDelta:0.003,longitudeDelta:0.003))
            region=target
            refreshMapSnapshot(force: true)
            camera = .region(target)
            model.selected=c
            queueCameraSave(target)
        } else if !restoredCamera {
            // Initialized directly from the saved region; do not recenter again.
            restoredCamera = true
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
    @State private var importBackup = false
    @State private var pendingBackup: Data?
    @State private var confirmRestore = false
    @State private var backupPassword = ""
    @State private var foursquareKeyEntry = ""
    @State private var foursquareConfigured = false
    @State private var foursquareStatus = ""

    @State private var secureExportFile: URL?
    @State private var message = ""
    @State private var exportFile: URL?
    @AppStorage("miMapaFaceID") private var faceIDEnabled = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Mi Mapa del Tiempo") {
                    Label("Versión 1.0.75 · datos guardados en este iPhone",
                          systemImage:"checkmark.shield")
                        .foregroundStyle(.teal)
                    Text("Tus visitas y zonas se conservan localmente. Puedes hacer una copia cifrada y recuperarla desde el apartado Copia de seguridad.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Seguimiento") {
                    LabeledContent("Estado", value: model.gpsStatus)
                    LabeledContent("Modo GPS",value:model.isResting ? "Pausa voluntaria · bajo consumo" :
                        model.recording ? "Continuo · máxima precisión" : "Detenido")
                    if let resting = model.restingCellName {
                        LabeledContent("Cuadrícula en pausa",value:resting)
                    }
                    Button(model.isResting ? "Reanudar GPS" :
                           model.recording ? "Detener GPS · seguir contando" : "Iniciar GPS continuo") {
                        if model.isResting { gps.begin(model) }
                        else if model.recording { gps.rest(model) }
                        else { gps.begin(model) }
                    }
                    .buttonStyle(.borderedProminent)
                    if model.recording || model.isResting {
                        Button("Detener seguimiento por completo",role:.destructive) {
                            gps.end(model)
                        }
                    }
                }
                GPSStaleWatchdogSettings(model:model)
                Section("Privacidad") {
                    Toggle("Solicitar Face ID o código", isOn:$faceIDEnabled)
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
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            Text("Opacidad de cuadrículas")
                            Spacer()
                            Text("\(Int(model.cellFillOpacity*100)) %")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value:$model.cellFillOpacity,in:0.08...1,step:0.04)
                            .tint(.teal)
                            .onChange(of:model.cellFillOpacity) { _,value in
                                UserDefaults.standard.set(value,forKey:"mapCellOpacityV13")
                            }
                    }
                    Toggle("Escala de colores adaptada",isOn:$model.adaptive)
                        .onChange(of:model.adaptive) { _,value in
                            UserDefaults.standard.set(value,forKey:"mapAdaptiveV5")
                        }
                }
                Section("Mis Sitios") {
                    Picker("Reconocer después de", selection: Binding(
                        get: { model.siteThresholdMinutes },
                        set: { model.setSiteThresholdMinutes($0) }
                    )) {
                        ForEach(SiteStayPolicy.allowedThresholds, id:\.self) { minutes in
                            Text("\(minutes) minutos").tag(minutes)
                        }
                    }
                    Text("La primera estancia te propone elegir un sitio sin interrumpirte. En visitas posteriores se asigna automáticamente el lugar más confirmado de esa cuadrícula; puedes corregirlo con un toque.")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Ver Mis Sitios") {
                        TimeMySitesView(model:model)
                    }
                }
                Section("Fuentes de lugares") {
                    Text("Foursquare es prioritario cuando está configurado. Sin clave se consultan OpenStreetMap y Apple, en ese orden. Las búsquedas solo ocurren al abrir el selector.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Image(systemName:foursquareConfigured ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(foursquareConfigured ? .teal : .secondary)
                        Text(foursquareConfigured ? "Foursquare activado" : "Foursquare sin configurar")
                            .font(.subheadline)
                    }
                    SecureField("Clave personal de Foursquare Places",text:$foursquareKeyEntry)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Button("Guardar de forma segura") {
                            if SiteFoursquareCredentials.save(foursquareKeyEntry) {
                                foursquareConfigured=true
                                foursquareStatus="Configuración guardada en el llavero de este iPhone."
                                foursquareKeyEntry=""
                            } else {
                                foursquareStatus="No se pudo guardar la configuración."
                            }
                        }
                        .disabled(foursquareKeyEntry.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        Spacer()
                        if foursquareConfigured {
                            Button("Desactivar") {
                                _ = SiteFoursquareCredentials.save("")
                                foursquareConfigured=false
                                foursquareKeyEntry=""
                                foursquareStatus="Foursquare desactivado."
                            }
                        }
                    }
                    if !foursquareStatus.isEmpty {
                        Text(foursquareStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("La API de Foursquare requiere una clave de desarrollador y puede facturar consultas. No hay claves insertadas en la aplicación. La clave personal no se incluye en la copia de datos ni en el repositorio.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .onAppear {
                    foursquareConfigured = SiteFoursquareCredentials.load() != nil
                }
                Section("Pantalla de bloqueo") {
                    NavigationLink("En vivo · pantalla bloqueada") {
                        TimeLiveSettingsView(model:model)
                    }
                }
                Section("Ayuda y diagnóstico") {
                    NavigationLink {
                        GPSGapReviewView(model:model)
                    } label: {
                        Label("Revisar todos los huecos GPS",systemImage:"location.slash.circle")
                    }
                    NavigationLink("Estado técnico del GPS y almacenamiento") {
                        GPSDiagnosticsView(model:model,gps:gps)
                    }
                }
                Section("Copia cifrada · sin iCloud obligatorio") {
                    SecureField("Contraseña de la copia (mín. 10 caracteres)",text:$backupPassword)
                        .textContentType(.newPassword)
                    Button("Preparar copia cifrada AES-256") {
                        do { secureExportFile=try model.exportEncryptedBackup(password:backupPassword) }
                        catch { message=error.localizedDescription }
                    }.disabled(backupPassword.count < 10)
                    if let secureExportFile {
                        ShareLink(item:secureExportFile) {
                            Label("Guardar copia en Archivos",systemImage:"icloud.and.arrow.up")
                        }
                    }
                    Button("Elegir copia .mmapbak para restaurar") {
                        importBackup=true
                    }.disabled(backupPassword.count < 10 || model.recording || model.isResting)
                    Text("Guarda la copia y su contraseña por separado. Restaurar reemplaza los datos.")
                        .font(.caption).foregroundStyle(.secondary)
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
            }
            .navigationTitle("Ajustes")
            .confirmationDialog("Esta acción sustituirá todos los datos locales",isPresented:$confirmRestore) {
                Button("Restaurar y sustituir historial",role:.destructive) {
                    guard let pendingBackup else { return }
                    do {
                        try model.restoreEncryptedBackup(pendingBackup,password:backupPassword)
                        message="Copia restaurada. GPS detenido hasta que lo actives."
                        self.pendingBackup=nil
                    } catch { message=error.localizedDescription }
                }
                Button("Cancelar",role:.cancel) { pendingBackup=nil }
            } message: {
                Text("Si necesitas conservar el historial actual, exporta antes una copia. Esta operación reemplaza las posiciones, zonas y nombres.")
            }
            .fileImporter(isPresented:$importBackup,
                allowedContentTypes:[UTType(filenameExtension:"mmapbak") ?? .data,.data]) { result in
                do {
                    let url=try result.get()
                    let granted=url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let bytes=try Data(contentsOf:url)
                    let details=try model.inspectEncryptedBackup(bytes,password:backupPassword)
                    pendingBackup=bytes
                    message="Copia válida: \(details). Confirma si quieres restaurar."
                    confirmRestore=true
                } catch { message=error.localizedDescription }
            }
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