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

    var isRaining: Bool { currentPrecipitation >= 0.1 }
    var upcomingWet: RainSample? {
        samples.first { $0.time > Date().addingTimeInterval(-300) && $0.precipitation >= 0.15 }
    }
    var firstDry: RainSample? {
        samples.first { $0.time > Date().addingTimeInterval(-300) && $0.precipitation < 0.08 }
    }
    var nextChange: Date? { isRaining ? firstDry?.time : upcomingWet?.time }
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
    var latest: RadarFrame? { frames.last }
}

enum RainAPI {
    static func fetchForecast(latitude: Double, longitude: Double, name: String) async throws -> RainSnapshot {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,precipitation"),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "hourly", value: "precipitation_probability,precipitation,temperature_2m"),
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
            days: daily
        )
    }

    static func fetchRadar() async throws -> RadarFeed {
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
        return RadarFeed(host: host, frames: frames)
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
    @Published var quickSummaries: [String: QuickRainSummary] = [:]
    @Published var quickFailures: Set<String> = []
    @Published var summariesLoading = false

    var pendingRefresh = false
    var summariesCheckedAt = Date.distantPast
    var placeSelectionRevision = 0

    private let location = RainLocation()
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastRefresh: Date = .distantPast

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
                self.name = "Mi ubicación"
                if moved { self.placeSelectionRevision += 1; await self.refresh(force: true) }
            }
            if moved {
                self.summariesCheckedAt = .distantPast
                await self.refreshSummaries(force: true)
            }
        }}
    }

    func start() {
        location.request()
        syncLive()
        Task {
            await refresh(force: true)
            await refreshSummaries(force: true)
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
            radar = try await rx
            radarIndex = max(0, radar.frames.count - 1)
            radarFutureMinutes = 0
        } catch {
            status += " · Radar no disponible"
        }
        // Only compute radar flow when we have two validated observations.
        let host = radar.host
        let frames = radar.frames
        let point = coordinate
        if frames.count >= 2 {
            let projected = await RadarNowcaster.forecast(host: host, frames: frames, coordinate: point)
            if selectedRevision != placeSelectionRevision { pendingRefresh = true; return }
            if projected != nil { projection = projected }
            if let p = projected ?? projection {
                let quality = Int(p.confidence * 100)
                projectionStatus = "Desplazamiento estimado · Confianza \(quality)% · Fiable orientativamente hasta +\(p.reliableUntil) min"
            } else {
                projectionStatus = "Sin vector radar fiable: se muestra orientación del modelo"
            }
        } else {
            projection = nil
            projectionStatus = "Radar insuficiente para estimar movimiento"
        }
        if liveEnabled { await updateLiveActivity() }
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
        let state = RainETAAttributes.ContentState(
            arrival: wx.nextChange,
            rainingNow: wx.isRaining,
            intensity: wx.intensity,
            updatedAt: wx.updatedAt,
            summary: wx.isRaining ? "Lluvia actual" : (wx.nextChange == nil ? "Sin lluvia inminente" : "Lluvia prevista")
        )
        let content = ActivityContent(state: state,
                                      staleDate: wx.updatedAt.addingTimeInterval(30 * 60),
                                      relevanceScore: 0.7)
        if let existing = Activity<RainETAAttributes>.activities.first {
            await existing.update(content)
            liveStatus = "En Vivo actualizada: \(existing.id.prefix(8))"
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                liveStatus = "Actividades En Vivo desactivadas en iOS"
                return
            }
            do {
                let created = try Activity<RainETAAttributes>.request(
                    attributes: RainETAAttributes(locationName: wx.locationName),
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
