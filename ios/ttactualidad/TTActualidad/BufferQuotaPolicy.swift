import Foundation

// A quota reading is captured from a real Buffer response header and stored
// by the existing publisher. It is never fetched by a new quota-only API call.
struct TTBufferQuotaObservation: Decodable {
    let observed_at: String
    let limit: Int
    let used: Int
    let sent_total: Int
}

struct TTBufferQuotaShortWindow: Decodable {
    let window_seconds: Int
    let limit: Int
    let remaining: Int
    let used: Int
    let resets_in_seconds: Int
}

struct TTBufferQuotaRate {
    let from: Date
    let through: Date
    let netRequests: Int
    let newConfirmedPosts: Int
    let days: Double

    var netRequestsPerDay: Double { Double(netRequests) / days }
    var observedRequestsPerNewPost: Double? {
        guard newConfirmedPosts > 0 && netRequests > 0 else { return nil }
        return Double(netRequests) / Double(newConfirmedPosts)
    }
}

enum TTBufferQuotaPolicy {
    private static func parse(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: raw) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    // Only compare two *actual*, chronologically distinct observations
    // with the same quota, at least an hour apart and at most seven days
    // apart. Never divide a 30-day used total by 30 or infer it from reset.
    // A rolling-window decrease means older calls may have expired: omit the
    // estimate rather than presenting a negative or misleading daily rate.
    static func recentRate(_ records: [TTBufferQuotaObservation]) -> TTBufferQuotaRate? {
        let valid = records.compactMap { item -> (Date, TTBufferQuotaObservation)? in
            guard let date = parse(item.observed_at), item.limit > 0,
                  item.used >= 0, item.used <= item.limit,
                  item.sent_total >= 0 else { return nil }
            return (date, item)
        }.sorted { $0.0 < $1.0 }
        guard let newest = valid.last else { return nil }

        let earlier = valid.first { old in
            let delta = newest.0.timeIntervalSince(old.0)
            return delta >= 3600 && delta <= 7 * 86400 &&
                newest.1.limit == old.1.limit &&
                newest.1.used >= old.1.used &&
                newest.1.sent_total >= old.1.sent_total
        }
        guard let earlier else { return nil }
        let days = newest.0.timeIntervalSince(earlier.0) / 86400.0
        guard days > 0 else { return nil }
        return TTBufferQuotaRate(
            from: earlier.0, through: newest.0,
            netRequests: newest.1.used - earlier.1.used,
            newConfirmedPosts: newest.1.sent_total - earlier.1.sent_total,
            days: days)
    }
}
