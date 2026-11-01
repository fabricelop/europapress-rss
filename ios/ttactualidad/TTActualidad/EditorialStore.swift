import ActivityKit
import Combine
import Foundation

enum EditorialSection: String, CaseIterable, Identifiable {
    case trends = "TTendencias"
    case news = "TTiTTulares"
    var id: String { rawValue }
}

enum TrendFilter: String, CaseIterable, Identifiable {
    case top = "Top 30"
    case listas = "Listas"
    case elaboracion = "En elaboración"
    var id: String { rawValue }
}
enum NewsFilter: String, CaseIterable, Identifiable {
    case listas = "Listas"
    case elaboracion = "En elaboración"
    case revision = "Revisión"
    case creciendo = "Creciendo"
    case tremending = "Tremending"
    var id: String { rawValue }
}

struct NewsItem: Identifiable {
    let id: String
    let title: String
    let text: String
    let publishedAt: Date?
    let revision: Int
    let sourceURL: URL?
    let imageURL: URL?
    let factual: String
    let closer: String
    let sources: Int
    var editorial: String { text }
    var status: String = "LISTA"

}

struct TrendItem: Identifiable {
    let id: String
    let rank: Int
    let name: String
    let explanation: String
    let lastExplained: Date?
    let status: String
    let inListas: Bool
    let editorialID: String
    let revision: Int
    // Immutable editorial identity for the original image, not the current request.
    let imageURL: URL?
    let sourceURL: URL?
    var imageEditorialID: String = ""
    var imageRevision: Int = 0
    var explainedAtRaw: String = ""

    func ageBand(now: Date = Date()) -> Int {
        guard let lastExplained else { return 0 }
        let hours = max(0, now.timeIntervalSince(lastExplained)) / 3600
        return hours < 12 ? 1 : hours <= 24 ? 2 : 3
    }
}

struct EditorialSnapshot {
    var news: [NewsItem] = []
    var newsElaboracion: [NewsItem] = []
    var newsRevision: [NewsItem] = []
    var newsCreciendo: [NewsItem] = []
    var newsTremending: [NewsItem] = []
    var top30: [TrendItem] = []
    var trendListas: [TrendItem] = []
    var trendsElaboracion: [TrendItem] = []
    var updatedAt: Date?
    var partial: Bool = true
}

@MainActor
final class EditorialStore: ObservableObject {
    @Published var section: EditorialSection = .trends
    @Published var trendFilter: TrendFilter = .top
    @Published var newsFilter: NewsFilter = .listas
    @Published private(set) var snapshot = EditorialSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var message = "Sin sincronizar"
    @Published private(set) var liveStatus = "Sin iniciar"

    // Canonical GitHub editorial sources. Not a Cloudflare or Vercel endpoint.
    private let paths = [
        "ttittulares/prepared.json",
        "ttittulares/decisions.json",
        "ttittulares/status.json",
        "ttittulares/editorial-queue.json",
        "ttittulares/tremending/items.json",
        "trends/recent.json",
        "trends/telegram-manual-explained.json",
        "trends/requests.json",
        "trends/explained.json",
        "trends/telegram-image-deliveries.json",
        "trends/mobile-decisions.json",
        "trends/editorial-queue.json"
    ]

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var downloaded: [String: Data] = [:]
        await withTaskGroup(of: (String, Data?).self) { group in
            for path in paths {
                group.addTask {
                    guard let url = URL(string: "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/" + path) else {
                        return (path, nil)
                    }
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 16)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200,
                              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                            return (path, nil)
                        }
                        return (path, data)
                    } catch {
                        return (path, nil)
                    }
                }
            }
            for await (path, data) in group {
                if let data { downloaded[path] = data }
            }
        }

        var docs: [String: [String: Any]] = [:]
        var partial = false
        for path in paths {
            let cacheURL = cacheFile(for: path)
            var source = downloaded[path]
            if let data = source {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            } else {
                partial = true
                source = try? Data(contentsOf: cacheURL)
            }
            if let source, let dict = (try? JSONSerialization.jsonObject(with: source)) as? [String: Any] {
                docs[path] = dict
            } else {
                partial = true
            }
        }

        // Never turn a temporary network error into false zeros in the Live Activity.
        guard docs["ttittulares/prepared.json"] != nil,
              docs["ttittulares/decisions.json"] != nil,
              docs["trends/telegram-manual-explained.json"] != nil,
              docs["trends/requests.json"] != nil,
              docs["trends/telegram-image-deliveries.json"] != nil,
              docs["trends/mobile-decisions.json"] != nil,
              docs["trends/editorial-queue.json"] != nil else {
            message = "Datos incompletos: conservando los últimos contadores"
            return
        }
        let fresh = !downloaded.isEmpty
        let now = fresh ? Date() : (snapshot.updatedAt ?? Date())
        // Archive photographs only. This GitHub listing cannot include the AI
        // directories because ArchivePhotoCatalog only selects archive-images.
        let archivePhotos = await ArchivePhotoCatalog.load()
        let news = Self.buildNews(prepared: docs["ttittulares/prepared.json"]!,
                                  decisions: docs["ttittulares/decisions.json"]!,
                                  archivePhotos: archivePhotos)
        let ready = Self.buildTrendListas(
            manual: docs["trends/telegram-manual-explained.json"]!,
            requests: docs["trends/requests.json"]!,
            deliveries: docs["trends/telegram-image-deliveries.json"]!,
            decisions: docs["trends/mobile-decisions.json"]!,
            queue: docs["trends/editorial-queue.json"]!,
            now: now, archivePhotos: archivePhotos
        )
        let top = Self.buildTop30(
            recent: docs["trends/recent.json"] ?? [:],
            manual: docs["trends/telegram-manual-explained.json"]!,
            explained: docs["trends/explained.json"] ?? [:],
            requests: docs["trends/requests.json"]!,
            ready: ready, archivePhotos: archivePhotos
        )
        let status = docs["ttittulares/status.json"] ?? [:]
        let newsQueue = docs["ttittulares/editorial-queue.json"] ?? [:]
        let newsTremending = docs["ttittulares/tremending/items.json"] ?? [:]
        let closures = Set(Self.rows(docs["ttittulares/decisions.json"]!, "items").filter {
            Self.closed.contains(Self.str($0, "status").lowercased())
        }.map { Self.str($0, "event_id") })
        let activeIDs = Set(Self.rows(newsQueue, "items").filter {
            ["PROCESSING", "UPDATE_PROCESSING"].contains(Self.str($0, "status").uppercased())
        }.map { Self.str($0, "event_id") })
        func sectionNews(_ list: [[String: Any]], _ kind: String) -> [NewsItem] {
            list.compactMap { item in
                let id = Self.str(item, "event_id").isEmpty ? Self.str(item, "id") : Self.str(item, "event_id")
                guard !id.isEmpty, !closures.contains(id),
                      !Self.closed.contains(Self.str(item, "status").lowercased())
                else { return nil }
                return NewsItem(id: id, title: Self.str(item, "title").isEmpty ?
                                  Self.str(item, "name") : Self.str(item, "title"),
                                text: Self.str(item, "explanation"),
                                publishedAt: Self.when(item, ["selected_at", "requested_at"]),
                                revision: Self.int(item, "revision"),
                                sourceURL: URL(string: Self.str(item, "url")),
                                imageURL: nil,
                                factual: Self.str(item, "factual_summary"),
                                closer: "", sources: Self.int(item, "source_count"),
                                status: kind)
            }
        }
        let processing = Self.rows(newsQueue, "items").filter {
            ["PROCESSING", "UPDATE_PROCESSING"].contains(Self.str($0, "status").uppercased())
        }
        let queueNews = sectionNews(processing.isEmpty ? Self.rows(status, "processing_items") : processing,
                                    "EN ELABORACIÓN")
        let problematic = sectionNews(Self.rows(status, "problematic_items").filter {
            !activeIDs.contains(Self.str($0, "event_id"))
        }, "REVISIÓN")
        let growing = sectionNews(Self.rows(status, "three_source_items").filter {
            !activeIDs.contains(Self.str($0, "event_id"))
        }, "CRECIENDO")
        let trending = sectionNews(Self.rows(newsTremending, "items"), "TREMENDING")
        let trendsQueued = Self.buildTrendsElaboracion(
            requests: docs["trends/requests.json"]!,
            queue: docs["trends/editorial-queue.json"]!,
            ready: ready
        )
        snapshot = EditorialSnapshot(news: news, newsElaboracion: queueNews,
                                     newsRevision: problematic, newsCreciendo: growing,
                                     newsTremending: trending,
                                     top30: top, trendListas: ready, trendsElaboracion: trendsQueued,
                                     updatedAt: now, partial: partial)
        message = partial ? "Datos parciales o en caché" : "Datos consultados directamente en GitHub"
        if fresh {
            await publishLiveCounts(news: news.count, trends: ready.count, checkedAt: now,
                                    partial: partial)
        }
    }

    private func cacheFile(for path: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TTActualidadGitHub", isDirectory: true)
            .appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    private static let closed: Set<String> = ["deleted", "dismissed", "published", "removed", "delete_pending"]

    private static func rows(_ doc: [String: Any], _ key: String) -> [[String: Any]] {
        doc[key] as? [[String: Any]] ?? []
    }
    private static func str(_ row: [String: Any], _ key: String) -> String {
        if let s = row[key] as? String { return s }
        if let n = row[key] as? NSNumber { return n.stringValue }
        return ""
    }
    private static func int(_ row: [String: Any], _ key: String) -> Int {
        (row[key] as? NSNumber)?.intValue ?? Int(str(row, key)) ?? 0
    }
    private static func when(_ row: [String: Any], _ keys: [String]) -> Date? {
        for key in keys {
            let text = str(row, key)
            if text.isEmpty { continue }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: text) { return date }
        }
        return nil
    }
    private static func norm(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
    private static func isNewer(_ row: [String: Any], than previous: [String: Any]?) -> Bool {
        guard let previous else { return true }
        let revision = int(row, "revision"), oldRevision = int(previous, "revision")
        if revision != oldRevision { return revision > oldRevision }
        return (when(row, ["updated_at", "deleted_at", "explained_at", "requested_at"]) ?? .distantPast) >=
            (when(previous, ["updated_at", "deleted_at", "explained_at", "requested_at"]) ?? .distantPast)
    }

    private static func buildNews(prepared: [String: Any], decisions: [String: Any],
                                  archivePhotos: [String: URL]) -> [NewsItem] {
        var statuses: [String: String] = [:]
        for item in rows(decisions, "items") {
            statuses[str(item, "event_id")] = str(item, "status").lowercased()
        }
        return rows(prepared, "items").compactMap { item in
            let id = str(item, "event_id")
            guard !id.isEmpty, !closed.contains(statuses[id] ?? "") else { return nil }
            let tweet = item["tweet"] as? [String: Any] ?? [:]
            let text = str(tweet, "text")
            let factual = str(item, "explanation").isEmpty ? str(item, "factual_summary") : str(item, "explanation")
            let preferred = text.isEmpty ? factual : text
            let archive = item["archive_image"] as? [String: Any] ??
                          item["fallback_image"] as? [String: Any] ?? [:]
            return NewsItem(id: id, title: str(item, "title"),
                            text: preferred,
                            publishedAt: when(item, ["prepared_at", "selected_at"]),
                            revision: int(item, "revision"),
                            sourceURL: URL(string: str(item, "url")),
                            imageURL: ArchivePhotoCatalog.resolved(
                                project: "ttittulares", id: id,
                                revision: int(item, "revision"),
                                image: URL(string: str(archive, "url")),
                                catalog: archivePhotos),
                            factual: factual,
                            closer: str(tweet, "remate").isEmpty ? str(item, "closer_text") : str(tweet, "remate"),
                            sources: int(item, "source_count"))
        }
    }

    private static func buildTrendListas(
        manual: [String: Any], requests: [String: Any], deliveries: [String: Any],
        decisions: [String: Any], queue: [String: Any], now: Date,
        archivePhotos: [String: URL]
    ) -> [TrendItem] {
        var latestManual: [String: [String: Any]] = [:]
        var latestRequests: [String: [String: Any]] = [:]
        var latestDeliveries: [String: [String: Any]] = [:]
        for row in rows(manual, "items") {
            let id = str(row, "id")
            if !id.isEmpty && isNewer(row, than: latestManual[id]) { latestManual[id] = row }
        }
        for row in rows(requests, "requests") {
            let id = str(row, "id")
            if !id.isEmpty && isNewer(row, than: latestRequests[id]) { latestRequests[id] = row }
        }
        for row in rows(deliveries, "items") {
            let id = str(row, "event_id")
            if !id.isEmpty && isNewer(row, than: latestDeliveries[id]) { latestDeliveries[id] = row }
        }
        let closures = rows(decisions, "items").filter { closed.contains(str($0, "status").lowercased()) }
        let activeQueue = rows(queue, "items")
        return latestManual.compactMap { id, row -> TrendItem? in
            guard str(row, "status").lowercased() == "explained",
                  !str(row, "explanation").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let explained = when(row, ["explained_at"]),
                  now.timeIntervalSince(explained) <= 48 * 3600,
                  explained.timeIntervalSince(now) <= 3600,
                  str(row, "group_leader_id").isEmpty || str(row, "group_leader_id") == id
            else { return nil }
            let rowRev = int(row, "revision")
            let req = latestRequests[id] ?? [:]
            let delivery = latestDeliveries[id] ?? [:]
            let reqRev = int(req, "revision"), reqStatus = str(req, "status").lowercased()
            // A radar revision may advance while the same explanation is
            // already persisted, as happened with #FelizJueves on 29 October.
            // Only link revisions when both the timestamp and exact text match.
            let sameEditorialEpisode = reqStatus == "explained"
                && abs((when(req, ["explained_at"]) ?? .distantPast).timeIntervalSince(explained)) <= 60
                && str(req, "explanation") == str(row, "explanation")
            let rev = reqRev > rowRev && sameEditorialEpisode ? reqRev : rowRev
            let readyAfterRequest = explained.timeIntervalSince(when(req, ["requested_at"]) ?? .distantPast) >= -60
            if !req.isEmpty && reqRev > rowRev && !sameEditorialEpisode { return nil }
            if ["preparing", "update", "ready"].contains(reqStatus) &&
                reqRev >= rev && !readyAfterRequest { return nil }
            if activeQueue.contains(where: {
                str($0, "id") == id &&
                ["preparing", "update"].contains(str($0, "status").lowercased()) &&
                int($0, "revision") > rev
            }) { return nil }
            if [str(row, "telegram_package_status"), str(req, "status"),
                str(req, "telegram_package_status")].contains(where: { closed.contains($0.lowercased()) }) {
                return nil
            }
            let closureApplies: ([String: Any]) -> Bool = { event in
                guard closed.contains(Self.str(event, "status").lowercased()) else { return false }
                let oldRev = Self.int(event, "revision")
                let closedAt = Self.when(event, ["deleted_at", "dismissed_at", "published_at",
                                                 "removed_at", "updated_at", "delivered_at", "decided_at"])
                // A weekly trend can reuse its editorial id with a revision
                // reset by its producer. A published r2 from 8 October must
                // not hide a freshly explained r0 from 29 October.
                // Ordering by a known timestamp takes precedence over
                // revision; revision is only the fallback for undated events.
                if let closedAt {
                    return closedAt.timeIntervalSince(explained) >= -60
                }
                return oldRev >= rev
            }
            if closures.contains(where: {
                [Self.str($0, "id"), Self.str($0, "event_id")].contains(id) && closureApplies($0)
            }) || closureApplies(delivery) { return nil }

            let archive = row["archive_image"] as? [String: Any] ??
                          row["fallback_image"] as? [String: Any] ?? [:]
            return TrendItem(id: id, rank: int(row, "rank"), name: str(row, "name"),
                             explanation: str(row, "explanation"), lastExplained: explained,
                             status: "EXPLICADA", inListas: true,
                             editorialID: id, revision: rev,
                             imageURL: ArchivePhotoCatalog.resolved(
                                 project: "ttendencias", id: id, revision: rev,
                                 image: URL(string: str(archive, "url")),
                                 catalog: archivePhotos),
                             sourceURL: URL(string: str(row, "source_url")),
                             imageEditorialID: id, imageRevision: rev,
                             explainedAtRaw: str(row, "explained_at"))
        }
        .sorted { ($0.lastExplained ?? .distantPast) > ($1.lastExplained ?? .distantPast) }
        .prefix(100)
        .map { $0 }
    }

    private static func buildTrendsElaboracion(
        requests: [String: Any], queue: [String: Any], ready: [TrendItem]
    ) -> [TrendItem] {
        let readyByID = Dictionary(uniqueKeysWithValues: ready.map { ($0.editorialID, $0.revision) })
        var result: [String: [String: Any]] = [:]
        for item in rows(requests, "requests") + rows(queue, "items") {
            let id = str(item, "id")
            let status = str(item, "status").lowercased()
            guard !id.isEmpty, ["preparing", "update"].contains(status),
                  int(item, "revision") > (readyByID[id] ?? -1) else { continue }
            if isNewer(item, than: result[id]) { result[id] = item }
        }
        return result.values.map { row in
            TrendItem(id: "work-" + str(row, "id"), rank: int(row, "rank"),
                      name: str(row, "name").isEmpty ? str(row, "id") : str(row, "name"),
                      explanation: str(row, "explanation"), lastExplained: when(row, ["explained_at"]),
                      status: "EN ELABORACIÓN", inListas: false,
                      editorialID: str(row, "id"), revision: int(row, "revision"),
                      imageURL: nil, sourceURL: URL(string: str(row, "source_url")),
                      imageEditorialID: str(row, "id"), imageRevision: int(row, "revision"),
                      explainedAtRaw: str(row, "explained_at"))
        }
        .sorted { ($0.lastExplained ?? .distantPast) > ($1.lastExplained ?? .distantPast) }
    }

    private static func buildTop30(
        recent: [String: Any], manual: [String: Any], explained: [String: Any],
        requests: [String: Any], ready: [TrendItem], archivePhotos: [String: URL]
    ) -> [TrendItem] {
        let names = recent["top30"] as? [String] ?? []
        let radar = rows(recent, "items")
        var byRank: [Int: String] = [:]
        for (index, row) in radar.enumerated() {
            let rank = int(row, "rank") == 0 ? index + 1 : int(row, "rank")
            if (1...30).contains(rank) && !str(row, "name").isEmpty {
                byRank[rank] = str(row, "name")
            }
        }
        for (i, name) in names.prefix(30).enumerated() {
            if byRank[i+1] == nil { byRank[i+1] = name }
        }

        let currentRequests = rows(requests, "requests")
        let histories = rows(manual, "items") + rows(explained, "items") + currentRequests
        var explanations: [String: [String: Any]] = [:]
        for row in histories where !str(row, "explanation").isEmpty {
            var names = [str(row, "name"), str(row, "display_name")]
            names += row["trend_names"] as? [String] ?? []
            names += (row["trend_context"] as? [[String: Any]] ?? []).map { str($0, "name") }
            for value in names where !value.isEmpty {
                let key = norm(value)
                let existing = explanations[key]
                if existing == nil ||
                    (when(row, ["updated_at", "explained_at"]) ?? .distantPast) >=
                     (when(existing!, ["updated_at", "explained_at"]) ?? .distantPast) {
                    explanations[key] = row
                }
            }
        }
        let readyNames = Set(ready.flatMap { row in [norm(row.name)] })
        var statuses: [String: String] = [:]
        var requestByName: [String: [String: Any]] = [:]
        for row in currentRequests {
            let key = norm(str(row, "name"))
            if key.isEmpty { continue }
            if isNewer(row, than: requestByName[key]) { requestByName[key] = row }
        }
        for (key, row) in requestByName {
            if ["preparing", "update", "ready"].contains(str(row, "status").lowercased()) {
                statuses[key] = "EN ELABORACIÓN"
            }
        }
        return (1...30).compactMap { rank -> TrendItem? in
            guard let name = byRank[rank], !name.isEmpty else { return nil }
            let key = norm(name), explanation = explanations[key] ?? [:]
            let text = str(explanation, "explanation")
            let date = when(explanation, ["explained_at"])
            let status: String = statuses[key] ??
                (text.isEmpty ? (rank > 10 ? "PREPARACIÓN MANUAL" : "PENDIENTE") : "EXPLICADA")
            let request = requestByName[key] ?? [:]
            let editorialID = str(request, "id").isEmpty ? str(explanation, "id") : str(request, "id")
            let revision = request.isEmpty ? int(explanation, "revision") : int(request, "revision")
            let archive = explanation["archive_image"] as? [String: Any] ??
                          explanation["fallback_image"] as? [String: Any] ?? [:]
            let source = str(request, "source_url")
            return TrendItem(id: "rank-\(rank)", rank: rank, name: name,
                             explanation: text, lastExplained: text.isEmpty ? nil : date,
                             status: status, inListas: readyNames.contains(key),
                             editorialID: editorialID, revision: revision,
                             imageURL: ArchivePhotoCatalog.resolved(
                                 project: "ttendencias", id: str(explanation, "id"),
                                 revision: int(explanation, "revision"), image: URL(string: str(archive, "url")),
                                 catalog: archivePhotos),
                             sourceURL: URL(string: source),
                             imageEditorialID: str(explanation, "id"),
                             imageRevision: int(explanation, "revision"),
                             explainedAtRaw: str(explanation, "explained_at"))
        }
    }

    private func publishLiveCounts(news: Int, trends: Int, checkedAt: Date,
                                   partial: Bool) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveStatus = "Activa las Live Activities en Ajustes del iPhone"
            return
        }
        let state = LiveCountsAttributes.ContentState(
            newsReady: news, trendsReady: trends,
            checkedAt: checkedAt, partialData: partial
        )
        let content = ActivityContent(state: state, staleDate: checkedAt.addingTimeInterval(30 * 60))
        do {
            if let active = Activity<LiveCountsAttributes>.activities.first {
                await active.update(content)
            } else {
                _ = try Activity<LiveCountsAttributes>.request(
                    attributes: LiveCountsAttributes(title: "TTActualidad"),
                    content: content, pushType: nil
                )
            }
            liveStatus = "Live Activity activa · actualización al abrir la app"
        } catch {
            liveStatus = "No se pudo iniciar la Live Activity: \(error.localizedDescription)"
        }
    }
}
