import Foundation

enum RankMovement {
    static func newNames(_ rows: [[String: Any]], now: Date = Date()) -> Set<String> {
        let basic = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Set(rows.compactMap { row -> String? in
            guard row["movement_version"] as? Int == 3,
                  row["movement"] as? String == "new",
                  let name = row["name"] as? String, !name.isEmpty,
                  let rank = row["rank"] as? Int, (1...30).contains(rank),
                  let raw = row["entered_top30_at"] as? String,
                  let entered = fractional.date(from: raw) ?? basic.date(from: raw),
                  now.timeIntervalSince(entered) >= 0, now.timeIntervalSince(entered) < 3600
            else { return nil }
            return name
        })
    }
}
