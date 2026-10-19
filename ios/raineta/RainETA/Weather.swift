import Foundation
import Combine
import CoreLocation
import ActivityKit

struct RainSample: Identifiable {
    var id: Int
    var time: Date
    var precipitation: Double
    var probability: Int?
}

struct HourlySnow {
    let end: Date
    let centimeters: Double
}

struct HourlyRain: Identifiable {
    var id: Int
    var time: Date
    var millimeters: Double
    var probability: Int
    var temperature: Double?
}

struct DailyRain: Identifiable {
    var id: Int
    var date: Date
    var totalMM: Double
    var probability: Int
    var minTemperature: Double?
    var maxTemperature: Double?
}

struct RainSnapshot {
    var updatedAt: Date
    var locationName: String
    var temperature: Double?
    var currentPrecipitation: Double
    var samples: [RainSample]
    var hours: [HourlyRain]
    var days: [DailyRain]
    // Snowfall data is modelled, typically hourly in cm. Radar alone
    // cannot determine the precipitation phase.
    var currentSnowfallCM: Double = 0
    var currentWeatherCode: Int? = nil
    var snowHours: [HourlySnow] = []

    func phase(at when: Date = Date()) -> RainPrecipitationPhase {
        let snow: Double
        if when.timeIntervalSince(updatedAt) >= -1800 &&
           when.timeIntervalSince(updatedAt) < 3600 {
            snow = currentSnowfallCM
            return RainPrecipitationPhase.classify(
                weatherCode: currentWeatherCode, snowfallCM: snow)
        }
        snow = snowHours.first(where: {
            $0.end.addingTimeInterval(-3600) <= when && when < $0.end
        })?.centimeters ?? 0
        return RainPrecipitationPhase.classify(weatherCode: nil,snowfallCM:snow)
    }

    var isRaining: Bool { currentPrecipitation >= 0.1 }
    var upcomingWet: RainSample? {
        samples.first { $0.time > Date().addingTimeInterval(-300) && $0.precipitation >= 0.15 }
    }
    var firstDry: RainSample? {
        samples.first { $0.time > Date().addingTimeInterval(-300) && $0.precipitation < 0.08 }
    }
    var nextChange: Date? {
        RainInsight.transition(currentIsRaining:isRaining,samples:samples,now:Date()).change
    }
    var intensity: String {
        let mm = isRaining ? currentPrecipitation : (upcomingWet?.precipitation ?? 0) * 4
        if mm < 0.3 { return "Llovizna" }
        if mm < 2.5 { return "Débil" }
        if mm < 7.5 { return "Moderada" }
        return "Fuerte"
    }
}

struct RadarFrame: Identifiable {
    var id: Int { timestamp }
    var timestamp: Int
    var path: String
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}
struct RadarFeed {
    var host: String = ""
    var frames: [RadarFrame] = []
    var future: [RadarFrame] = []
    var source = "RainViewer"
    var latest: RadarFrame? { frames.last }
    var hasNowcast: Bool { !future.isEmpty }
}

enum RainAPI {
    static func fetchForecast(latitude: Double, longitude: Double, name: String) async throws -> RainSnapshot {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,precipitation,snowfall,weather_code"),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "hourly", value: "precipitation_probability,precipitation,temperature_2m,snowfall"),
            URLQueryItem(name: "daily", value: "precipitation_sum,precipitation_probability_max,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        let offset = root["utc_offset_seconds"] as? Int ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(secondsFromGMT: 0)!
        let fine = root["minutely_15"] as? [String: Any] ?? [:]
        let hours = root["hourly"] as? [String: Any] ?? [:]
        let hourTimes = (hours["time"] as? [String] ?? []).compactMap(formatter.date(from:))
        let hourlyProb = hours["precipitation_probability"] as? [Double] ?? []
        let hourlyAmounts = hours["precipitation"] as? [Double] ?? []
        let hourlyTemps = hours["temperature_2m"] as? [Double] ?? []
        let hourlySnowfall = hours["snowfall"] as? [Double] ?? []
        let snowHours = hourTimes.enumerated().compactMap { index,date -> HourlySnow? in
            guard index < hourlySnowfall.count else {return nil}
            return HourlySnow(end:date,centimeters:max(0,hourlySnowfall[index]))
        }
        let times = fine["time"] as? [String] ?? []
        let amounts = fine["precipitation"] as? [Double] ?? []
        let now = Date()
        var samples: [RainSample] = []
        for (idx, raw) in times.enumerated() {
            guard idx < amounts.count, let date = formatter.date(from: raw),
                  date >= now.addingTimeInterval(-900), date <= now.addingTimeInterval(24 * 3600) else { continue }
            let closest = hourTimes.enumerated().min(by: {
                abs($0.element.timeIntervalSince(date)) < abs($1.element.timeIntervalSince(date))
            })?.offset
            let chance = closest.flatMap { $0 < hourlyProb.count ? Int(hourlyProb[$0]) : nil }
            samples.append(RainSample(id: idx, time: date, precipitation: max(0, amounts[idx]), probability: chance))
        }
        let extended = hourTimes.enumerated().compactMap { idx, date -> HourlyRain? in
            guard idx < hourlyAmounts.count, idx < hourlyProb.count else { return nil }
            return HourlyRain(id: idx, time: date, millimeters: max(0, hourlyAmounts[idx]),
                              probability: max(0, min(100, Int(hourlyProb[idx]))),
                              temperature: idx < hourlyTemps.count ? hourlyTemps[idx] : nil)
        }
        let dayData = root["daily"] as? [String: Any] ?? [:]
        let dayDates = (dayData["time"] as? [String] ?? []).compactMap { raw -> Date? in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = formatter.timeZone
            df.dateFormat = "yyyy-MM-dd"
            return df.date(from: raw)
        }
        let dayAmounts = dayData["precipitation_sum"] as? [Double] ?? []
        let dayProb = dayData["precipitation_probability_max"] as? [Double] ?? []
        let dayMin = dayData["temperature_2m_min"] as? [Double] ?? []
        let dayMax = dayData["temperature_2m_max"] as? [Double] ?? []
        let daily = dayDates.enumerated().compactMap { index, date -> DailyRain? in
            guard index < dayAmounts.count else { return nil }
            return DailyRain(id: index, date: date,
                             totalMM: max(0, dayAmounts[index]),
                             probability: index < dayProb.count ? Int(dayProb[index]) : 0,
                             minTemperature: index < dayMin.count ? dayMin[index] : nil,
                             maxTemperature: index < dayMax.count ? dayMax[index] : nil)
        }
        let current = root["current"] as? [String: Any] ?? [:]
        return RainSnapshot(
            updatedAt: Date(),
            locationName: name,
            temperature: current["temperature_2m"] as? Double,
            currentPrecipitation: current["precipitation"] as? Double ?? 0,
            samples: samples,
            hours: extended,
            days: daily,
            currentSnowfallCM: max(0,current["snowfall"] as? Double ?? 0),
            currentWeatherCode: current["weather_code"] as? Int,
            snowHours: snowHours
        )
    }

    static func availableHistory(_ frames:[RadarFrame],now:Date=Date()) -> [RadarFrame] {
        let cutoff=now.addingTimeInterval(-2*3600).timeIntervalSince1970
        return frames.filter { Double($0.timestamp)>=cutoff && $0.date<=now }
            .sorted{$0.timestamp<$1.timestamp}
    }

    static func fetchRadar() async throws -> RadarFeed {
        // A coherent radar/nowcast tile set is preferable to switching to
        // unrelated hourly WMS raster fields at +5 minutes. LibreWXR supplies
        // an experimental 60-minute nowcast in the same tile style. Its
        // metadata must be genuinely fresh; otherwise use RainViewer observed
        // history with no invented future.
        if let live = try? await fetchLibreNowcast() { return live }
        return try await fetchObservedRadar()
    }

    static func fetchLibreNowcast(now:Date=Date()) async throws -> RadarFeed {
        let url=URL(string:"https://api.librewxr.net/public/weather-maps.json")!
        var request=URLRequest(url:url)
        request.timeoutInterval=8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data,response)=try await URLSession.shared.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode==200,
              let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let host=root["host"] as? String,
              host=="https://api.librewxr.net",
              let generated=root["generated"] as? Int,
              abs(now.timeIntervalSince1970-Double(generated))<15*60,
              let radar=root["radar"] as? [String:Any],
              let past=radar["past"] as? [[String:Any]],
              let future=radar["nowcast"] as? [[String:Any]] else {
            throw URLError(.badServerResponse)
        }
        func read(_ rows:[[String:Any]]) -> [RadarFrame] {
            rows.compactMap { row -> RadarFrame? in
                guard let time=row["time"] as? Int,
                      let path=row["path"] as? String,
                      path.hasPrefix("/v2/radar/") else {return nil}
                return RadarFrame(timestamp:time,path:path)
            }.sorted {$0.timestamp<$1.timestamp}
        }
        let observations=availableHistory(read(past),now:now)
        let newFrames=read(future)
        guard let last=observations.last,
              now.timeIntervalSince(last.date)>=0,
              now.timeIntervalSince(last.date)<20*60 else {
            throw URLError(.cannotParseResponse)
        }
        let steps=newFrames.filter {$0.timestamp>last.timestamp &&
                                    $0.timestamp<=last.timestamp+3600}
        guard steps.count>=3 else { throw URLError(.cannotParseResponse) }
        return RadarFeed(host:host,frames:observations,future:steps,
                         source:"LibreWXR")
    }

    static func fetchObservedRadar() async throws -> RadarFeed {
        let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = root["host"] as? String,
              let radar = root["radar"] as? [String: Any],
              let past = radar["past"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        let frames = past.compactMap { row -> RadarFrame? in
            guard let time = row["time"] as? Int, let path = row["path"] as? String else { return nil }
            return RadarFrame(timestamp: time, path: path)
        }.sorted { $0.timestamp < $1.timestamp }
        // RainViewer may supply fewer than two hours; never fabricate earlier
        // observations or extend its licensed frame history.
        return RadarFeed(host: host, frames: availableHistory(frames),
                         future:[],source:"RainViewer")
    }
}

final class RainLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onCoordinate: ((CLLocationCoordinate2D) -> Void)?
    var onDenied: (() -> Void)?
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 500
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: locationManagerDidChangeAuthorization(manager)
        default: onDenied?()
        }
    }

    func requestAlways() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        } else {
            onAuthorization?(manager.authorizationStatus)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(manager.authorizationStatus)
        switch manager.authorizationStatus {
        case .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = true
            manager.startMonitoringSignificantLocationChanges()
            manager.requestLocation()
        case .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted: onDenied?()
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let point = locations.last?.coordinate else { return }
        onCoordinate?(point)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}

@MainActor final class RainStore: ObservableObject {
    @Published var coordinate = CLLocationCoordinate2D(latitude: 40.4168, longitude: -3.7038)
    @Published var name = "Madrid · provisional"
    @Published var snapshot: RainSnapshot?
    @Published var radar = RadarFeed()
    @Published var projection: RadarProjection?
    @Published var shortEstimate: RainShortEstimate?
    @Published private(set) var radarLocal: RadarLocalTimeline?
    @Published private(set) var radarAnalysisStatus = "Comprobando radar local…"
    @Published private(set) var shortModels: [RainShortModel] = []
    @Published private(set) var shortModelsUpdatedAt: Date?
    @Published private(set) var shortModelsLoading = false
    @Published var futureField: FutureRainField?
    @Published var futureFieldStatus = "Previsión DWD ICON-EU por horas. Pulsa +2 h o +4 h para consultar el modelo oficial."
    @Published var projectionStatus = "Calculando desplazamiento de la lluvia…"
    @Published var loading = false
    @Published var status = "Consultando datos meteorológicos"
    @Published var liveEnabled = false
    @Published var liveStatus = "En Vivo desactivada"
    @Published var locationPermission = "Comprobando ubicación"
    @Published var radarIndex = 0
    @Published var radarFutureMinutes = 0
    @Published var gpsCoordinate: CLLocationCoordinate2D?
    @Published var savedPlaces: [SavedRainPlace] = []
    @Published var selectedPlaceID = "gps"
    @Published var gpsPlaceName = "Ubicación GPS"
    @Published var quickSummaries: [String: QuickRainSummary] = [:]
    @Published var quickFailures: Set<String> = []
    @Published var summariesLoading = false

    var pendingRefresh = false
    var summariesCheckedAt = Date.distantPast
    var placeSelectionRevision = 0

    private let location = RainLocation()
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastRefresh: Date = .distantPast
    private var modelTask: Task<Void, Never>?
    private var modelSerial = 0
    private var modelCenter = CLLocationCoordinate2D(latitude: 40.4168, longitude: -3.7038)
    private var modelLatSpan = 2.5
    private var modelLonSpan = 2.5
    private var fieldLastLoad: Date = .distantPast
    private var shortTask: Task<Void, Never>?
    private var shortLocationKey = ""
    private var shortModelKey = ""
    private var shortModelLoadedAt: Date = .distantPast
    private var cachedRadarKey = ""
    private var cachedRadarEvidence: RainRadarEvidence?

    init() {
        liveEnabled = !Activity<RainETAAttributes>.activities.isEmpty
        liveStatus = liveEnabled ? "Actividad En Vivo detectada en iOS" : "En Vivo desactivada"
        if let data = UserDefaults.standard.data(forKey: "raineta.savedPlaces.v1"),
           let found = try? JSONDecoder().decode([SavedRainPlace].self, from: data) {
            savedPlaces = found
        }
        selectedPlaceID = UserDefaults.standard.string(forKey: "raineta.selectedPlace.v1") ?? "gps"
        if let selected = savedPlaces.first(where: { $0.id == selectedPlaceID }) {
            coordinate = selected.coordinate
            name = selected.name
        } else {
            selectedPlaceID = "gps"
        }
        location.onDenied = { [weak self] in Task { @MainActor in
            self?.locationPermission = "Ubicación denegada; revisar Ajustes"
            self?.status = "Ubicación no autorizada: mostrando Madrid como ejemplo"
        }}
        location.onAuthorization = { [weak self] permission in Task { @MainActor in
            switch permission {
            case .authorizedAlways: self?.locationPermission = "Ubicación: Siempre"
            case .authorizedWhenInUse: self?.locationPermission = "Ubicación: Mientras se usa · Solicitar Siempre"
            case .notDetermined: self?.locationPermission = "Ubicación pendiente"
            default: self?.locationPermission = "Ubicación restringida"
            }
        }}
        location.onCoordinate = { [weak self] point in Task { @MainActor in
            guard let self else { return }
            let moved = self.lastCoordinate.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) > 1000
            } ?? true
            self.gpsCoordinate = point
            self.lastCoordinate = point
            if self.selectedPlaceID == "gps" {
                self.coordinate = point
                self.name = self.gpsPlaceName
                if moved { self.placeSelectionRevision += 1; await self.refresh(force: true) }
            }
            if moved {
                Task { await self.resolveGPSPlaceName(point) }
                self.summariesCheckedAt = .distantPast
                await self.refreshSummaries(force: true)
            }
        }}
    }

    private func resolveGPSPlaceName(_ point: CLLocationCoordinate2D) async {
        // Locality from Apple's reverse-geocoder, not a guess based on
        // the nearest previously selected saved location.
        let fallback = String(format: "GPS %.3f, %.3f", point.latitude, point.longitude)
        let resolved: String
        do {
            let geocoder = CLGeocoder()
            let marks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: point.latitude, longitude: point.longitude),
                preferredLocale: Locale(identifier: "es_ES")
            )
            let place = marks.first
            let city = [place?.locality, place?.subAdministrativeArea, place?.administrativeArea]
                .compactMap { $0 }.first { !$0.isEmpty }
            resolved = city.map { "\($0) · GPS" } ?? fallback
        } catch {
            resolved = fallback
        }
        guard let latest = gpsCoordinate,
              abs(latest.latitude-point.latitude) < 0.015,
              abs(latest.longitude-point.longitude) < 0.015 else { return }
        gpsPlaceName = resolved
        if selectedPlaceID == "gps" {
            name = resolved
            if liveEnabled, snapshot != nil { await updateLiveActivity() }
        }
    }

    func updateLivePlaceWhileLoading() async {
        guard !Activity<RainETAAttributes>.activities.isEmpty else { return }
        let pending = RainETAAttributes.ContentState(
            arrival: nil,
            rainingNow: false,
            intensity: "Pendiente",
            updatedAt: Date(),
            summary: "Actualizando previsión",
            locationName: name
        )
        for activity in Activity<RainETAAttributes>.activities {
            await activity.update(ActivityContent(state: pending,
                                                  staleDate: Date().addingTimeInterval(90)))
        }
        liveStatus = "En Vivo: \(name) · actualizando"
    }

    func start() {
        location.request()
        syncLive()
        Task {
            await refresh(force: true)
            await refreshSummaries(force: true)
        }
    }

    func requestFutureField(center:CLLocationCoordinate2D,latSpan:Double,lonSpan:Double,
                            force:Bool = false) {
        guard center.latitude.isFinite,center.longitude.isFinite,
              latSpan.isFinite,lonSpan.isFinite,
              abs(center.latitude) < 84,abs(center.longitude) < 178 else { return }
        let la = min(20,max(0.03,abs(latSpan)))
        let lo = min(35,max(0.03,abs(lonSpan)))
        if !force,let existing = futureField,
           Date().timeIntervalSince(fieldLastLoad) < 10*60,
           existing.covers(center:center,latSpan:la,lonSpan:lo) { return }
        let old = FutureRainField.worldPoint(modelCenter)
        let new = FutureRainField.worldPoint(center)
        let sameTarget = abs(old.x-new.x) < modelLonSpan/720*0.1 &&
                         abs(old.y-new.y) < modelLatSpan/360*0.1 &&
                         abs(lo-modelLonSpan) < modelLonSpan*0.12 &&
                         abs(la-modelLatSpan) < modelLatSpan*0.12
        if !force,sameTarget,modelTask != nil { return }
        modelTask?.cancel()
        modelSerial += 1
        let serial = modelSerial
        let revision = placeSelectionRevision
        modelCenter = center
        modelLatSpan = la
        modelLonSpan = lo
        futureFieldStatus = "Consultando precipitación espacial de modelos…"
        modelTask = Task {
            if !force {
                try? await Task.sleep(nanoseconds: 850_000_000)
            }
            guard !Task.isCancelled else { return }
            do {
                let grid = try await FutureRainAPI.fetch(center:center,latSpan:la,lonSpan:lo)
                guard !Task.isCancelled,serial == modelSerial,
                      revision == placeSelectionRevision else { return }
                futureField = grid
                fieldLastLoad = Date()
                futureFieldStatus = "Modelo espacial Open-Meteo · \(Int(grid.completeness*100))% de puntos disponibles · nuevos datos por cada consulta"
            } catch {
                guard !Task.isCancelled,serial == modelSerial else { return }
                futureFieldStatus = "Modelo espacial no disponible: \(error.localizedDescription). Radar observado conservado."
            }
            if serial == modelSerial { modelTask = nil }
        }
    }

    func requestAlwaysLocation() {
        location.requestAlways()
        if location.authorizationStatus == .authorizedWhenInUse {
            locationPermission = "Solicitud de ubicación Siempre enviada; si no aparece, habilitar en Ajustes"
        }
    }

    func syncLive() {
        liveEnabled = !Activity<RainETAAttributes>.activities.isEmpty
        if liveEnabled {
            liveStatus = "En Vivo activa · \(Activity<RainETAAttributes>.activities.count) actividad(es) detectada(s)"
        } else {
            liveStatus = "En Vivo no iniciada"
        }
    }

    func refresh(force: Bool = false) async {
        if loading {
            if force { pendingRefresh = true }
            return
        }
        if !force && Date().timeIntervalSince(lastRefresh) < 120 { return }
        loading = true
        defer {
            loading = false
            if pendingRefresh {
                pendingRefresh = false
                Task { await self.refresh(force: true) }
            }
        }
        let selectedRevision = placeSelectionRevision
        async let wx = RainAPI.fetchForecast(latitude: coordinate.latitude, longitude: coordinate.longitude, name: name)
        async let rx = RainAPI.fetchRadar()
        do {
            let updated = try await wx
            if selectedRevision != placeSelectionRevision {
                pendingRefresh = true
                return
            }
            snapshot = updated
            lastRefresh = Date()
            status = "Previsión de Open-Meteo · orientativa"
        } catch {
            status = "Error en la previsión. Conservamos los últimos datos."
        }
        if selectedRevision != placeSelectionRevision { pendingRefresh = true; return }
        do {
            let lastSelected = radar.frames.indices.contains(radarIndex) ?
                               radar.frames[radarIndex].timestamp : nil
            let atNow = radarFutureMinutes == 0 && radarIndex >= max(0,radar.frames.count-1)
            radar = try await rx
            if radar.future.isEmpty && radarFutureMinutes>0 {
                // Weather source went offline: never keep a future position
                // whose tile was not actually published by the replacement.
                radarFutureMinutes=0
            }
            if radarFutureMinutes > 0 || atNow {
                radarIndex = max(0, radar.frames.count-1)
            } else if let lastSelected {
                // Preserve the historical timestamp across periodic refresh.
                radarIndex = radar.frames.enumerated().min(by: {
                    abs($0.element.timestamp-lastSelected)<abs($1.element.timestamp-lastSelected)
                })?.offset ?? 0
            }
        } catch {
            status += " · Radar no disponible"
        }
        // Legacy translation/fade projection disabled. Its geographic motion
        // was not verified and disappeared at high zoom. Show observation
        // honestly until model-grid / radar-blending validation is complete.
        projection = nil
        projectionStatus = "Cuenta atrás: estimación local de radar contrastada con modelos cuando hay datos recientes y fiables."
        refreshShortEstimate()
        if liveEnabled { await updateLiveActivity() }
    }

    /// Run the expensive radar analysis outside the main refresh path. The
    /// countdown is always available from the original forecast while the
    /// new estimate is loading; stale results cannot cross locations.
    /// All short-range consumers (hero, Live Activity, minute Pulse, 3h chart)
    /// use the same radar-led local estimate. Model updates and radar sampling
    /// run concurrently. No stale place-specific results may overwrite a move.
    private func refreshShortEstimate() {
        guard let wx=snapshot else{return}
        shortTask?.cancel()
        let coord=coordinate
        let locationKey=String(format:"%.3f,%.3f",coord.latitude,coord.longitude)
        let changed=shortLocationKey != locationKey
        if changed {
            shortEstimate=nil
            radarLocal=nil
            shortModels=[]
            shortModelsUpdatedAt=nil
            shortLocationKey=locationKey
        }
        let feed=radar
        let modelsCache=shortModelKey==locationKey ? shortModels : []
        let reuse=shortModelKey==locationKey && !modelsCache.isEmpty &&
                  Date().timeIntervalSince(shortModelLoadedAt)<10*60
        shortModelsLoading = !reuse
        radarAnalysisStatus="Comprobando píxel radar de " + name + "…"
        let revision=placeSelectionRevision

        shortTask=Task {
            async let radarResult=RadarLocalAPI.fetch(feed:feed,coordinate:coord)
            async let modelResult:[RainShortModel] = reuse ? modelsCache :
                RainShortModelAPI.compare(latitude:coord.latitude,longitude:coord.longitude)
            let local=await radarResult
            // Publish radar detection promptly, without waiting for up to
            // five slower model providers. The original snapshot is usable.
            guard !Task.isCancelled,revision==placeSelectionRevision,
                  shortLocationKey==locationKey else{return}
            radarLocal=local
            if let local,local.isFresh(at:Date()) {
                radarAnalysisStatus="Radar local válido · \(feed.source) · observado " +
                    local.observedAt.formatted(date:.omitted,time:.shortened)
            } else {
                radarAnalysisStatus=feed.source=="LibreWXR" ?
                    "Sin lectura radar local válida; modelos de respaldo" :
                    "No se pudo leer el radar de este lugar; modelos sin confirmar"
            }
            shortEstimate=RainShortFusion.estimateUsingLocal(
                 weather:wx,radar:local,models:modelsCache,now:Date())
            if liveEnabled {await updateLiveActivity()}

            let received=await modelResult
            guard !Task.isCancelled,revision==placeSelectionRevision,
                  shortLocationKey==locationKey else{return}
            let models=received.isEmpty && shortModelKey==locationKey &&
                      Date().timeIntervalSince(shortModelLoadedAt)<30*60 ?
                      modelsCache : received
            if !reuse && !received.isEmpty {
                shortModels=received
                shortModelKey=locationKey
                shortModelLoadedAt=Date()
                shortModelsUpdatedAt=Date()
            }
            shortModelsLoading=false
            shortEstimate=RainShortFusion.estimateUsingLocal(
                 weather:wx,radar:local,models:models,now:Date())
            if liveEnabled {await updateLiveActivity()}
        }
    }

    func minuteForecast(now:Date,horizon:Int) -> [RadarWeightedMinute] {
        guard let snapshot else{return []}
        let recentRadar=radarLocal?.isFresh(at:now)==true ? radarLocal:nil
        return RadarWeightedForecast.make(snapshot:snapshot,models:shortModels,
                                         radar:recentRadar,now:now,horizon:horizon)
    }

    func toggleLive() async {
        syncLive()
        if liveEnabled {
            for activity in Activity<RainETAAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            syncLive()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveStatus = "iOS no permite En Vivo: revisar Ajustes > RainETA > Actividades en Vivo"
            return
        }
        guard snapshot != nil else {
            liveStatus = "Espera a que se descargue la primera previsión"
            return
        }
        await updateLiveActivity()
    }

    func updateLiveActivity() async {
        guard let wx = snapshot else { return }
        let decision = shortEstimate?.isUsable(at: Date()) == true ? shortEstimate : nil
        let rainingNow = decision?.rainingNow ?? wx.isRaining
        let arrival = decision?.change ?? wx.nextChange
        let state = RainETAAttributes.ContentState(
            arrival: arrival,
            rainingNow: rainingNow,
            intensity: wx.intensity,
            updatedAt: wx.updatedAt,
            summary: rainingNow ? "Lluvia estimada ahora" : (arrival == nil ? "Sin lluvia inminente" : "Lluvia prevista"),
            locationName: name
        )
        let content = ActivityContent(state: state,
                                      staleDate: wx.updatedAt.addingTimeInterval(30 * 60),
                                      relevanceScore: 0.7)
        if let existing = Activity<RainETAAttributes>.activities.first {
            await existing.update(content)
            liveStatus = "En Vivo: \(name) · actualizada"
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                liveStatus = "Actividades En Vivo desactivadas en iOS"
                return
            }
            do {
                let created = try Activity<RainETAAttributes>.request(
                    attributes: RainETAAttributes(locationName: name),
                    content: content,
                    pushType: nil
                )
                liveStatus = "En Vivo solicitada a iOS: \(created.id.prefix(8)) · \(created.activityState)"
            } catch {
                liveStatus = "Error de En Vivo: \(error.localizedDescription)"
            }
        }
        syncLive()
    }
}
