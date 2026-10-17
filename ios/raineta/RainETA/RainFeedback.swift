import Foundation

/// A report is a local observation, not an automatic rain-gauge reading.
/// Keep it on the device and compare only forecasts issued before the report.
struct RainReport: Codable {
    let date: Date
    let latitude: Double
    let longitude: Double
    let raining: Bool
    let modelWet: [String: Bool]
}

enum RainFeedback {
    private static let key = "raineta.observations.v1"

    static func load() -> [RainReport] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RainReport].self, from: data)) ?? []
    }

    static func save(_ reports: [RainReport], now: Date = Date()) {
        let recent = Array(reports.filter { now.timeIntervalSince($0.date) < 30 * 86400 }
            .suffix(100))
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func near(_ report: RainReport, latitude: Double, longitude: Double) -> Bool {
        let dy = (report.latitude - latitude) * 111_000
        let dx = (report.longitude - longitude) * 111_000 * cos(latitude * .pi / 180)
        return hypot(dx, dy) <= 2_000
    }

    /// At least five local reports are needed. A smoothed score limits a
    /// model's influence to 0.75...1.25, so one tap cannot train the forecast.
    static func weights(_ reports: [RainReport], latitude: Double,
                        longitude: Double, now: Date) -> [String: Double] {
        let nearby = reports.filter {
            let age = now.timeIntervalSince($0.date)
            return age >= 0 && age < 14 * 86400 &&
                near($0, latitude: latitude, longitude: longitude)
        }
        let names = Set(nearby.flatMap { $0.modelWet.keys })
        return Dictionary(uniqueKeysWithValues: names.compactMap { name -> (String, Double)? in
            let checked = nearby.compactMap { report -> Bool? in
                report.modelWet[name].map { $0 == report.raining }
            }
            let baseline: Double
            if checked.count >= 5 {
                let accuracy = (Double(checked.filter { $0 }.count) + 3) /
                               (Double(checked.count) + 6)
                baseline = min(1.25, max(0.75, 0.75 + 0.5 * accuracy))
            } else {
                baseline = 1
            }
            // One local correction is immediately useful, but only briefly.
            // Never exclude a model completely: the observation is subjective.
            let recent = nearby.filter {
                now.timeIntervalSince($0.date) < 20 * 60 &&
                $0.modelWet[name] != nil
            }.max(by: {$0.date < $1.date})
            guard let recent else {
                return checked.count >= 5 ? (name, baseline) : nil
            }
            let age = now.timeIntervalSince(recent.date)
            let decay = max(0, 1 - age / (20 * 60))
            let factor = recent.modelWet[name] == recent.raining ?
                1 + 0.12 * decay : 1 - 0.35 * decay
            return (name, min(1.25, max(0.60, baseline * factor)))
        })
    }
}
