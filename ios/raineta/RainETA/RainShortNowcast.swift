import Foundation

/// A local radar estimate is an extrapolation of observed echoes. Its one-minute
/// points are NOT new observations, physical mm/h or independent model forecasts.
struct RainRadarEvidence {
    let observedAt: Date
    let movementConfidence: Double
    let points: [RadarMinute]
}

struct RainShortModel {
    let name: String
    /// The precipitation value is the accumulation for the preceding hour.
    let hours: [(end: Date, mm: Double)]

    func predictsRain(at date: Date) -> Bool? {
        guard let bucket = hours.first(where: {
            $0.end.addingTimeInterval(-3600) <= date && date < $0.end
        }) else { return nil }
        return bucket.mm >= 0.1
    }
}

struct RainShortEstimate {
    let issuedAt: Date
    let change: Date?
    let rainingNow: Bool
    let method: String
    let confidence: String
    let windowStart: Date?
    let windowEnd: Date?
    let radarBased: Bool

    func isUsable(at date: Date) -> Bool {
        date.timeIntervalSince(issuedAt) >= -60 &&
        date.timeIntervalSince(issuedAt) < (radarBased ? 12*60 : 30*60) &&
        (change == nil || change! > date.addingTimeInterval(-90))
    }
}

enum RainShortFusion {
    private static func wet(_ signal: Double) -> Bool { signal >= 0.14 }

    /// Reject one-minute speckles and short gaps. Do not report an exact onset
    /// until a sustained echo (at least 7 of 9 future points) is projected.
    private static func sustained(_ values: [Double], from index: Int, targetWet: Bool) -> Bool {
        guard index >= 0 && index+9 <= values.count else { return false }
        let count = values[index..<index+9].filter { wet($0) == targetWet }.count
        return count >= 7
    }

    static func estimate(weather: RainSnapshot, radar: RainRadarEvidence?,
                         models: [RainShortModel], now: Date) -> RainShortEstimate {
        let fallback = RainInsight.transition(currentIsRaining: weather.isRaining,
                                              samples: weather.samples, now: now)
        let modelResult = RainShortEstimate(issuedAt: now, change: fallback.change,
                                            rainingNow: fallback.raining,
                                            method: "Modelo · intervalos de 15 min",
                                            confidence: "Orientativo", windowStart: nil,
                                            windowEnd: nil, radarBased: false)
        guard let radar, radar.movementConfidence >= 0.38,
              radar.movementConfidence.isFinite,
              !radar.points.isEmpty else { return modelResult }
        let ageMinutes = Int(floor(now.timeIntervalSince(radar.observedAt)/60))
        guard (0...12).contains(ageMinutes) else { return modelResult }

        let ordered = radar.points.sorted { $0.minute < $1.minute }
        // The forecast from RadarNowcaster is anchored to the last observation,
        // not to the time the network request finishes.
        guard ordered.first?.minute == 0, ordered.count >= ageMinutes + 100,
              ordered.enumerated().allSatisfy({ $0.element.minute == $0.offset }) else {
            return modelResult
        }
        let values = ordered.map(\.signal)
        let wetNow = sustained(values, from: ageMinutes, targetWet: true)
        let dryNow = sustained(values, from: ageMinutes, targetWet: false)
        guard wetNow != dryNow else { return modelResult }

        let futureWet = !wetNow
        let upper = min(values.count-9, ageMinutes+120)
        guard upper >= ageMinutes+5 else { return modelResult }
        var changeOffset: Int?
        for minute in (ageMinutes+5)...upper {
            if sustained(values, from: minute, targetWet: futureWet) {
                changeOffset = minute-ageMinutes
                break
            }
        }
        // Do not invent a transition if the radar remains dry/wet for 2 hours.
        guard let offset = changeOffset else { return modelResult }
        let change = now.addingTimeInterval(TimeInterval(offset*60))

        let votes = models.compactMap { $0.predictsRain(at: change) }
        let agree = votes.filter { $0 == futureWet }.count
        let disagree = votes.count - agree
        // Clear contrary model guidance + weak radar motion: avoid a misleading
        // high-confidence minute. The standard forecast remains on screen.
        if disagree >= 2 && radar.movementConfidence < 0.65 { return modelResult }
        let consensus = votes.count >= 2 && agree >= 2
        let uncertainty = min(45, 8 + offset/6 +
                              (radar.movementConfidence < 0.7 ? 10 : 0) +
                              (disagree > 0 ? 10 : 0) +
                              (votes.count < 2 ? 8 : 0))
        let reliable = radar.movementConfidence >= 0.75 && offset <= 30 &&
                       consensus && disagree == 0
        let caption: String
        if consensus {
            caption = "Radar + modelos"
        } else if disagree > 0 {
            caption = "Radar · modelos discrepan"
        } else {
            caption = "Radar · sin consenso suficiente"
        }
        return RainShortEstimate(
            issuedAt: now, change: change, rainingNow: wetNow,
            method: caption, confidence: reliable ? "Confianza media" : "Confianza baja",
            windowStart: change.addingTimeInterval(Double(-uncertainty*60)),
            windowEnd: change.addingTimeInterval(Double(uncertainty*60)),
            radarBased: true
        )
    }
}

/// Optional coarse hourly cross-check. These sources do not provide physically
/// independent one-minute rainfall forecasts. Failed calls never block the
/// existing Open-Meteo countdown.
enum RainShortModelAPI {
    static let endpoints: [(name: String, url: String)] = [
        ("ECMWF", "https://api.open-meteo.com/v1/ecmwf"),
        ("ICON", "https://api.open-meteo.com/v1/dwd-icon"),
        ("GFS", "https://api.open-meteo.com/v1/gfs")
    ]

    static func parse(name: String, data: Data) -> RainShortModel? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String],
              let amounts = hourly["precipitation"] as? [Any] else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let values: [(end: Date, mm: Double)] = zip(times, amounts).compactMap { value in
            guard let date = df.date(from: value.0),
                  let number = value.1 as? NSNumber else { return nil }
            return (end: date, mm: max(0, number.doubleValue))
        }
        guard values.count >= 2 else { return nil }
        return RainShortModel(name: name, hours: values)
    }

    static func compare(latitude: Double, longitude: Double) async -> [RainShortModel] {
        await withTaskGroup(of: RainShortModel?.self) { group in
            for source in endpoints {
                group.addTask {
                    guard var query = URLComponents(string: source.url) else { return nil }
                    query.queryItems = [
                        URLQueryItem(name: "latitude", value: String(latitude)),
                        URLQueryItem(name: "longitude", value: String(longitude)),
                        URLQueryItem(name: "hourly", value: "precipitation"),
                        URLQueryItem(name: "forecast_hours", value: "6"),
                        URLQueryItem(name: "timezone", value: "GMT")
                    ]
                    guard let url = query.url else { return nil }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 9
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return parse(name: source.name, data: data)
                }
            }
            var results: [RainShortModel] = []
            for await item in group { if let item { results.append(item) } }
            return endpoints.compactMap { endpoint in
                results.first { $0.name == endpoint.name }
            }
        }
    }
}
