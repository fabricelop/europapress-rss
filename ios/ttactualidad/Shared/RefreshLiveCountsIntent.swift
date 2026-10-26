import ActivityKit
import AppIntents
import Foundation

// User-initiated refresh from the Live Activity. No push infrastructure,
// BackgroundTasks entitlement or Home Screen widget is required.
struct RefreshLiveCountsIntent: AppIntent {
    static var title: LocalizedStringResource = "Actualizar TTActualidad"
    static var description = IntentDescription("Consulta los estados editoriales en GitHub y actualiza la Live Activity.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let source = try await LiveCountsSource.load()
        let now = Date()
        let state = LiveCountsAttributes.ContentState(newsReady: source.news,
                                                       trendsReady: source.trends,
                                                       checkedAt: now, partialData: false)
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(1800))
        for activity in Activity<LiveCountsAttributes>.activities {
            await activity.update(content)
        }
        return .result()
    }
}

private enum LiveCountsSource {
    private static let base = "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/"
    private static let required = [
        "ttittulares/prepared.json", "ttittulares/decisions.json",
        "trends/telegram-manual-explained.json", "trends/requests.json",
        "trends/telegram-image-deliveries.json", "trends/mobile-decisions.json",
        "trends/editorial-queue.json"
    ]
    private static let terminal: Set<String> =
        ["deleted", "dismissed", "published", "removed", "delete_pending"]

    struct Counts { let news: Int; let trends: Int }

    static func load() async throws -> Counts {
        var docs: [String: [String: Any]] = [:]
        // Explicitly fail on a partial read: never overwrite good counters with zero.
        for path in required {
            guard let url = URL(string: base + path) else { throw URLError(.badURL) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 12)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { throw URLError(.badServerResponse) }
            docs[path] = dict
        }

        let prepared = rows(docs["ttittulares/prepared.json"], "items")
        let decisions = rows(docs["ttittulares/decisions.json"], "items")
        let closedNews = Set(decisions.filter {
            terminal.contains(str($0, "status").lowercased())
        }.map { str($0, "event_id") })
        let news = prepared.filter {
            let id = str($0, "event_id")
            return !id.isEmpty && !closedNews.contains(id)
        }.count

        var latestManual: [String: [String: Any]] = [:]
        var latestRequests: [String: [String: Any]] = [:]
        var latestDeliveries: [String: [String: Any]] = [:]
        for item in rows(docs["trends/telegram-manual-explained.json"], "items") {
            let id = str(item, "id")
            if !id.isEmpty && newer(item, than: latestManual[id]) { latestManual[id] = item }
        }
        for item in rows(docs["trends/requests.json"], "requests") {
            let id = str(item, "id")
            if !id.isEmpty && newer(item, than: latestRequests[id]) { latestRequests[id] = item }
        }
        for item in rows(docs["trends/telegram-image-deliveries.json"], "items") {
            let id = str(item, "event_id")
            if !id.isEmpty && newer(item, than: latestDeliveries[id]) { latestDeliveries[id] = item }
        }
        let closures = rows(docs["trends/mobile-decisions.json"], "items")
            .filter { terminal.contains(str($0, "status").lowercased()) }
        let queue = rows(docs["trends/editorial-queue.json"], "items")
        let now = Date()
        let trends = latestManual.filter { id, item in
            guard str(item, "status").lowercased() == "explained",
                  !str(item, "explanation").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let explained = date(str(item, "explained_at")),
                  now.timeIntervalSince(explained) <= 48 * 3600,
                  explained.timeIntervalSince(now) <= 3600 else { return false }
            let leader = str(item, "group_leader_id")
            if !leader.isEmpty && leader != id { return false }
            let rev = integer(item, "revision")
            let req = latestRequests[id] ?? [:]
            let delivery = latestDeliveries[id] ?? [:]
            let reqStatus = str(req, "status").lowercased()
            if !req.isEmpty && integer(req, "revision") > rev { return false }
            let readyAfterRequest = explained.timeIntervalSince(date(str(req, "requested_at")) ?? .distantPast) >= -60
            if ["preparing", "update", "ready"].contains(reqStatus) &&
                integer(req, "revision") >= rev && !readyAfterRequest { return false }
            if queue.contains(where: {
                str($0, "id") == id && ["preparing", "update"].contains(str($0, "status").lowercased()) &&
                integer($0, "revision") > rev
            }) { return false }
            if [str(item, "telegram_package_status"), reqStatus,
                str(req, "telegram_package_status")].contains(where: {
                terminal.contains($0.lowercased())
            }) { return false }
            let closed: ([String: Any]) -> Bool = { receipt in
                guard terminal.contains(str(receipt, "status").lowercased()) else { return false }
                let oldRev = integer(receipt, "revision")
                if oldRev != rev { return oldRev > rev }
                let closedAt = ["deleted_at", "dismissed_at", "published_at",
                                "removed_at", "updated_at", "delivered_at", "decided_at"]
                    .compactMap { date(str(receipt, $0)) }.first
                return !(closedAt != nil && closedAt!.timeIntervalSince(explained) < -60)
            }
            if closures.contains(where: {
                [str($0, "id"), str($0, "event_id")].contains(id) && closed($0)
            }) || closed(delivery) { return false }
            return true
        }.count
        return Counts(news: news, trends: trends)
    }

    private static func rows(_ doc: [String: Any]?, _ field: String) -> [[String: Any]] {
        doc?[field] as? [[String: Any]] ?? []
    }
    private static func str(_ doc: [String: Any], _ key: String) -> String {
        if let value = doc[key] as? String { return value }
        if let number = doc[key] as? NSNumber { return number.stringValue }
        return ""
    }
    private static func integer(_ doc: [String: Any], _ key: String) -> Int {
        (doc[key] as? NSNumber)?.intValue ?? Int(str(doc, key)) ?? 0
    }
    private static func date(_ value: String) -> Date? {
        if value.isEmpty { return nil }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? standard.date(from: value)
    }
    private static func newer(_ row: [String: Any], than previous: [String: Any]?) -> Bool {
        guard let previous else { return true }
        let a = integer(row, "revision"), b = integer(previous, "revision")
        if a != b { return a > b }
        let keys = ["updated_at", "deleted_at", "explained_at", "requested_at"]
        let x = keys.compactMap { date(str(row, $0)) }.first ?? .distantPast
        let y = keys.compactMap { date(str(previous, $0)) }.first ?? .distantPast
        return x >= y
    }
}