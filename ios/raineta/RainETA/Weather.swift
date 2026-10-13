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

struct RainSnapshot {
    var updatedAt: Date
    var locationName: String
    var temperature: Double?
    var currentPrecipitation: Double
    var samples: [RainSample]

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
            URLQueryItem(name: "hourly", value: "precipitation_probability,precipitation"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "3")
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
        let current = root["current"] as? [String: Any] ?? [:]
        return RainSnapshot(
            updatedAt: Date(),
            locationName: name,
            temperature: current["temperature_2m"] as? Double,
            currentPrecipitation: current["precipitation"] as? Double ?? 0,
            samples: samples
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
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }
    func request() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        } else { onDenied?() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        } else if manager.authorizationStatus == .denied { onDenied?() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onCoordinate?(location.coordinate)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}

@MainActor final class RainStore: ObservableObject {
    @Published var coordinate = CLLocationCoordinate2D(latitude: 40.4168, longitude: -3.7038)
    @Published var name = "Madrid · provisional"
    @Published var snapshot: RainSnapshot?
    @Published var radar = RadarFeed()
    @Published var loading = false
    @Published var status = "Consultando datos meteorológicos"
    @Published var liveEnabled = false
    @Published var radarOffset = 0

    private let location = RainLocation()
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastRefresh: Date = .distantPast

    init() {
        location.onDenied = { [weak self] in Task { @MainActor in
            self?.status = "Ubicación no autorizada: mostrando Madrid como ejemplo"
        }}
        location.onCoordinate = { [weak self] point in Task { @MainActor in
            guard let self else { return }
            let moved = self.lastCoordinate.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude)) > 1000
            } ?? true
            self.coordinate = point
            self.name = "Mi ubicación"
            self.lastCoordinate = point
            if moved { await self.refresh(force: true) }
        }}
        liveEnabled = UserDefaults.standard.bool(forKey: "raineta.liveRequested")
    }

    func start() {
        location.request()
        Task { await refresh(force: true) }
    }

    func refresh(force: Bool = false) async {
        if loading { return }
        if !force && Date().timeIntervalSince(lastRefresh) < 120 { return }
        loading = true
        defer { loading = false }
        async let wx = RainAPI.fetchForecast(latitude: coordinate.latitude, longitude: coordinate.longitude, name: name)
        async let rx = RainAPI.fetchRadar()
        do {
            snapshot = try await wx
            lastRefresh = Date()
            status = "Previsión de Open-Meteo · orientativa"
        } catch {
            status = "Error en la previsión. Conservamos los últimos datos."
        }
        do {
            let loaded = try await rx
            radar = loaded
            radarOffset = 0
        } catch {
            status += " · Radar no disponible"
        }
        if liveEnabled { await updateLiveActivity() }
    }

    func toggleLive() async {
        if liveEnabled {
            for activity in Activity<RainETAAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            liveEnabled = false
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                status = "Activa Actividades en Vivo en Ajustes del iPhone"
                return
            }
            guard snapshot?.nextChange != nil else {
                status = "Todavía no hay un comienzo o final de lluvia que mostrar en Vivo"
                return
            }
            liveEnabled = true
            await updateLiveActivity()
        }
        UserDefaults.standard.set(liveEnabled, forKey: "raineta.liveRequested")
    }

    private func updateLiveActivity() async {
        guard let wx = snapshot, let change = wx.nextChange else { return }
        let state = RainETAAttributes.ContentState(
            arrival: change,
            rainingNow: wx.isRaining,
            intensity: wx.intensity,
            updatedAt: wx.updatedAt
        )
        let content = ActivityContent(state: state, staleDate: wx.updatedAt.addingTimeInterval(30 * 60))
        if let activity = Activity<RainETAAttributes>.activities.first {
            await activity.update(content)
        } else {
            do {
                _ = try Activity<RainETAAttributes>.request(
                    attributes: RainETAAttributes(locationName: wx.locationName),
                    content: content,
                    pushType: nil
                )
            } catch {
                status = "No se pudo iniciar En Vivo: \(error.localizedDescription)"
                liveEnabled = false
            }
        }
    }
}
