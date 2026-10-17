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
    /// Native or API-resampled preceding-hour precipitation sums (mm).
    /// Each bucket is averaged over the hour, never a measured minute value.
    let hours: [(end: Date, mm: Double)]

    func rateMMH(at date: Date) -> Double? {
        guard let bucket = hours.first(where: {
            $0.end.addingTimeInterval(-3600) <= date && date < $0.end
        }), bucket.mm.isFinite else { return nil }
        return max(0, bucket.mm) // a 1h sum is numerically the hourly mean mm/h
    }

    func predictsRain(at date: Date) -> Bool? {
        rateMMH(at: date).map { $0 >= 0.1 }
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
    let radarObservedAt: Date?

    func isUsable(at date: Date) -> Bool {
        date.timeIntervalSince(issuedAt) >= -60 &&
        date.timeIntervalSince(issuedAt) < (radarBased ? 12*60 : 30*60) &&
        (!radarBased || (radarObservedAt != nil &&
          date.timeIntervalSince(radarObservedAt!) < 15*60)) &&
        (change == nil || change! > date.addingTimeInterval(-90))
    }
}

enum RainShortFusion {
    static func estimateUsingLocal(weather:RainSnapshot,
                                   radar:RadarLocalTimeline?,
                                   models:[RainShortModel],now:Date)
         -> RainShortEstimate {
        let fallback=RainInsight.transition(
            currentIsRaining:weather.isRaining,samples:weather.samples,now:now)
        guard let radar,radar.isFresh(at:now) else {
            return RainShortEstimate(issuedAt:now,change:fallback.change,
                rainingNow:fallback.raining,method:"Modelos · radar no disponible",
                confidence:"Orientativo",windowStart:nil,windowEnd:nil,
                radarBased:false,radarObservedAt:nil)
        }
        let series=RadarWeightedForecast.make(snapshot:weather,models:models,
                              radar:radar,now:now,horizon:180)
        let decision=RadarWeightedForecast.transition(series:series,
                             at:now,observation:weather.isRaining)
        // A dry radar observation vetoes a model claiming that rain has
        // already started. Only use fallback changes outside the radar-led
        // 90-minute interval.
        // A model's "rain will END" timestamp must never be reused as
        // the "rain will START" countdown after a dry radar observation.
        // They are opposite transitions and would create a false ETA.
        let later=fallback.change.flatMap { change in
            fallback.raining == decision.wet &&
            change.timeIntervalSince(now)>90*60 ? change:nil
        }
        let change=decision.change ?? later
        let offset=change.map{max(0,$0.timeIntervalSince(now)/60)} ?? 120
        let margin=offset<=60 ? 10.0 : 20.0
        return RainShortEstimate(
            issuedAt:now,change:change,rainingNow:decision.wet,
            method:radar.hasFutureFrames ? "Radar observado + nowcast hasta 60 min" :
                                         "Radar observado · futuro por modelos",
            confidence:offset<=60 ? "Confianza orientativa":"Confianza baja",
            windowStart:change?.addingTimeInterval(-margin*60),
            windowEnd:change?.addingTimeInterval(margin*60),
            radarBased:true,radarObservedAt:radar.observedAt)
    }

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
                                            windowEnd: nil, radarBased: false,
                                            radarObservedAt: nil)
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
            radarBased: true, radarObservedAt: radar.observedAt
        )
    }
}

/// Optional coarse hourly cross-check. These sources do not provide physically
/// independent one-minute rainfall forecasts. Failed calls never block the
/// existing Open-Meteo countdown.
enum RainShortModelAPI {
    /// Sources are from distinct forecast centres, not duplicate Open-Meteo
    /// 'best match' responses. All endpoints provide hourly rain amounts.
    static let endpoints: [(name: String, url: String)] = [
        ("ECMWF", "https://api.open-meteo.com/v1/ecmwf"),
        ("ICON", "https://api.open-meteo.com/v1/dwd-icon"),
        ("GFS", "https://api.open-meteo.com/v1/gfs"),
        ("ARPEGE", "https://api.open-meteo.com/v1/meteofrance"),
        ("UKMO", "https://api.open-meteo.com/v1/ukmo")
    ]

    static func parse(name: String, data: Data) -> RainShortModel? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Any],
              let amounts = hourly["precipitation"] as? [Any] else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let values: [(end: Date, mm: Double)] = zip(times, amounts).compactMap { rawTime, amount in
            let time: Date?
            if let unix = rawTime as? NSNumber {
                time = Date(timeIntervalSince1970: unix.doubleValue)
            } else if let text = rawTime as? String {
                time = parser.date(from: text)
            } else {
                time = nil
            }
            guard let date = time, let number = amount as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return (end: date, mm: number.doubleValue)
        }
        guard values.count >= 2 else { return nil }
        return RainShortModel(name: name, hours: values.sorted { $0.end < $1.end })
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
                        URLQueryItem(name: "past_hours", value: "2"),
                        URLQueryItem(name: "forecast_hours", value: "8"),
                        URLQueryItem(name: "timezone", value: "GMT"),
                        // Unix timestamps avoid DST and timezone mismatch.
                        URLQueryItem(name: "timeformat", value: "unixtime")
                    ]
                    guard let url = query.url else { return nil }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 12
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
