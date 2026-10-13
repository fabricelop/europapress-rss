import Foundation
import CoreLocation

struct SavedRainPlace: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    let latitude: Double
    let longitude: Double

    init(id: String = UUID().uuidString, name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct FoundRainPlace: Identifiable, Decodable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?

    var caption: String {
        [name, admin1, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct QuickRainSummary {
    let checkedAt: Date
    let raining: Bool
    let nextRain: Date?
    let until: Date?
    let temperature: Double?
    let status: String
    let dryWindow: String
    let source: String

    var nowLabel: String { raining ? "LLUEVE" : "NO LLUEVE" }
    var nextLabel: String {
        if raining { return "Ahora" }
        guard let nextRain else { return "Sin lluvia 24 h" }
        return nextRain.formatted(date: .omitted, time: .shortened)
    }
    var untilLabel: String {
        until?.formatted(date: .omitted, time: .shortened) ?? "—"
    }
    var temperatureLabel: String {
        guard let temperature else { return "—" }
        return String(format: "%.1f°", temperature)
    }
}

enum RainPlacesAPI {
    private struct SearchResponse: Decodable { let results: [FoundRainPlace]? }

    static func find(_ text: String) async throws -> [FoundRainPlace] {
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [
            URLQueryItem(name: "name", value: text),
            URLQueryItem(name: "count", value: "12"),
            URLQueryItem(name: "language", value: "es"),
            URLQueryItem(name: "format", value: "json")
        ]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        let results = decoded.results ?? []
        return results.sorted { a,b in
            let aSpain = a.country == "España" || a.country == "Spain"
            let bSpain = b.country == "España" || b.country == "Spain"
            if aSpain != bSpain { return aSpain }
            return a.caption < b.caption
        }
    }

    static func quick(latitude: Double, longitude: Double) async throws -> QuickRainSummary {
        // Lightweight 24-hour view, intentionally separate from the full
        // seven-day model and radar used by the selected location.
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String((latitude * 1000).rounded()/1000)),
            URLQueryItem(name: "longitude", value: String((longitude * 1000).rounded()/1000)),
            URLQueryItem(name: "current", value: "temperature_2m,precipitation"),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String:Any] else {
            throw URLError(.badServerResponse)
        }
        let offset = root["utc_offset_seconds"] as? Int ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(secondsFromGMT: 0)!
        let raw = root["minutely_15"] as? [String:Any] ?? [:]
        let dates = raw["time"] as? [String] ?? []
        let amounts = raw["precipitation"] as? [Double] ?? []
        let current = root["current"] as? [String:Any] ?? [:]
        let currentMM = current["precipitation"] as? Double ?? 0
        let raining = currentMM >= 0.1
        let now = Date()
        var timeline: [(date:Date, amount:Double)] = []
        for (index, text) in dates.enumerated() {
            guard index < amounts.count, let date = formatter.date(from:text),
                  date >= now.addingTimeInterval(-900),
                  date <= now.addingTimeInterval(86400) else { continue }
            timeline.append((date, max(0, amounts[index])))
        }
        let futureWetIndex = timeline.firstIndex(where: { $0.amount >= 0.1 })
        let nextRain = futureWetIndex.map { timeline[$0].date }
        var end: Date?
        if raining {
            // Require two dry intervals, avoiding brief gaps masquerading as end.
            for i in 0..<max(0, timeline.count-1) where timeline[i].amount < 0.08 &&
                  timeline[i+1].amount < 0.08 {
                end = timeline[i].date
                break
            }
        } else if let start = futureWetIndex {
            for i in (start+1)..<max(start+1, timeline.count-1) where
                timeline[i].amount < 0.08 && timeline[i+1].amount < 0.08 {
                end = timeline[i].date
                break
            }
        }
        let dry = raining ? "Lluvia ahora" :
            (nextRain.map { "Seco ~\(max(0, Int($0.timeIntervalSince(now)/60))) min" } ?? "Sin señal en 24 h")
        return QuickRainSummary(checkedAt: now, raining: raining, nextRain: nextRain,
                                until: end,
                                temperature: current["temperature_2m"] as? Double,
                                status: "Modelo 15 min",
                                dryWindow: dry,
                                source: "Open-Meteo · estimación")
    }
}
