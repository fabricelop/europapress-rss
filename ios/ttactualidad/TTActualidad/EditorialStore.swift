import ActivityKit
import Combine
import CryptoKit
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
    case recientes = "Recientes"
    case pendientes = "Pendientes"
    case antiguas = "Antiguas"
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
    let imageURL: URL?
    let sourceURL: URL?
    // AI image is independent from archive photographs.
    var siteImageURL: URL? = nil
    var rankDelta: Int = 0
    var movement: String = ""
    var enteredAt: Date? = nil
    var problemReason: String = ""
    var coveredByID: String = ""
    var coveredByName: String = ""
    var isJointGroup: Bool = false
    var lastReviewed: Date? = nil
    var reviewOutcome: String = ""
    var reviewReason: String = ""
    // Site attachment needs the ORIGINAL editorial ID and literal ISO timestamp.
    // Do not derive these from a name, ranking position or a newer request.
    var siteImageEditorialID: String = ""
    var siteImageRevision: Int = 0
    var siteImageExplainedAt: String = ""
    var isCovered: Bool { !coveredByID.isEmpty }

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
    var unexplainedTrends: [TrendItem] = []
    var updatedAt: Date?
    var partial: Bool = true
    var oneSourceCount: Int? = nil
    var twoSourceCount: Int? = nil
    var oneSourceDelta: Int? = nil
    var twoSourceDelta: Int? = nil
    var radarAt: Date? = nil
    var trendsRadarAt: Date? = nil
    var trendsRadarReliability: String = ""
}

// UI changes immediately; GitHub remains the authority for persisted decisions.
struct OptimisticEditorialAction {
    enum Phase { case sending, confirmed, uncertain }
    let project: String
    let id: String
    let revision: Int
    let decision: String
    let title: String
    let rank: Int
    let requestID: String
    var phase: Phase = .sending

    var key: String { project + ":" + id + ":r" + String(revision) }
}

// Terminal decisions are durable. A stale or partially cached GitHub JSON
// cannot resurrect a deleted card on a later app launch.
private struct EditorialTombstone: Codable {
    let project: String
    let id: String
    let revision: Int
    let decision: String
    let confirmedAt: Date
}

private struct PublicationEvent {
    let project: String
    let eventID: String
    let revision: Int
    let confirmedAt: Date
}

struct ConfirmedPublication: Identifiable {
    let project: String
    let eventID: String
    let revision: Int
    let confirmedAt: Date
    let title: String?

    var id: String {
        project + ":" + eventID + ":r" + String(revision)
    }
}

struct EditorialOperation: Codable, Identifiable {
    let id: String
    let title: String
    let kind: String
    var status: String
    let createdAt: Date
    var requestID: String? = nil
    var project: String? = nil
    var eventID: String? = nil
    var revision: Int? = nil
    var detail: String? = nil

    var isOutstanding: Bool {
        // A confirmed editorial job belongs in the En elaboración tab;
        // it is NOT a still-unacknowledged GitHub command.
        ["Enviando", "Esperando GitHub", "Pendiente de GitHub",
         "Sin confirmar"].contains(status)
    }
    var displayKind: String {
        switch kind {
        case "deleted": return "No publicado · retirar de Listas"
        case "published": return "Publicado · retirar de Listas"
        case "discard": return "Desestimar"
        case "prepare", "rework": return "Elaborar desde cero"
        case "hints": return "Aportar pistas e investigar"
        case "Nueva noticia": return "Añadir noticia"
        case "De tendencia a noticia": return "Tendencia → TTiTTulares"
        default: return kind
        }
    }
    var displayProject: String {
        project == "ttendencias" ? "TTendencias" : "TTiTTulares"
    }
}

@MainActor
final class EditorialStore: ObservableObject {
    @Published var section: EditorialSection = .trends
    @Published var trendFilter: TrendFilter = .top
    @Published var newsFilter: NewsFilter = .listas
    @Published private(set) var snapshot = EditorialSnapshot()
    @Published private(set) var publicationLedgerAvailable = false
    @Published private var publicationEvents: [PublicationEvent] = []

    // Exactly (now - 86,400 seconds, now], not midnight-based and never
    // inferred from intent-to-tweet, discard or historical status records.
    func publicationsLast24h(project: String, now: Date = Date()) -> Int? {
        guard publicationLedgerAvailable else { return nil }
        return publicationsHistoryLast24h(project: project, now: now)?.count
    }

    // Oldest record first, with stable tie-breaking by project/event/revision.
    // The UI numbers rows backwards, so the first (oldest) gets N.
    func publicationsHistoryLast24h(
        project: String, now: Date = Date()
    ) -> [ConfirmedPublication]? {
        guard publicationLedgerAvailable else { return nil }
        let lowerBound = now.addingTimeInterval(-86_400)
        return publicationEvents.filter {
            $0.project == project &&
            $0.confirmedAt > lowerBound && $0.confirmedAt <= now
        }
        .sorted {
            if $0.confirmedAt != $1.confirmedAt {
                return $0.confirmedAt < $1.confirmedAt
            }
            return ($0.project + ":" + $0.eventID + ":r" + String($0.revision)) <
                   ($1.project + ":" + $1.eventID + ":r" + String($1.revision))
        }
        .map { event in
            let title = operationHistory.first {
                $0.kind == "published" &&
                $0.project == event.project &&
                $0.eventID == event.eventID &&
                $0.revision == event.revision
            }?.title
            return ConfirmedPublication(
                project: event.project, eventID: event.eventID,
                revision: event.revision, confirmedAt: event.confirmedAt,
                title: title
            )
        }
    }
    @Published private(set) var isLoading = false
    private(set) var editorialReadFreshness: [String: Bool] = [:]
    @Published private(set) var message = "Sin sincronizar"
    @Published private(set) var liveStatus = "Sin iniciar"
    @Published private(set) var novedades: [String] = []
    @Published private(set) var actionMessage = ""
    @Published private(set) var actionIsError = false
    @Published private(set) var activeEditorialActions: [String: OptimisticEditorialAction] = [:]
    @Published private(set) var unreviewedNews = Set<String>()
    @Published private(set) var unreviewedTrends = Set<String>()
    @Published private(set) var radarNewNames = Set<String>()
    @Published private(set) var operationHistory: [EditorialOperation] = []
    private var reviewedNews = Set<String>()
    private var reviewedTrends = Set<String>()
    var allNews: [NewsItem] {
        var seen = Set<String>()
        return (snapshot.news + snapshot.newsElaboracion + snapshot.newsRevision +
                snapshot.newsCreciendo + snapshot.newsTremending).filter { seen.insert($0.id).inserted }
    }
    var pendingOperationsCount: Int {
        operationHistory.filter(\.isOutstanding).count
    }
    var outstandingOperations: [EditorialOperation] {
        operationHistory.filter(\.isOutstanding)
    }
    var recentOperations: [EditorialOperation] {
        Array(operationHistory.filter { !$0.isOutstanding }.prefix(5))
    }
    private var canonicalSnapshot = EditorialSnapshot()
    private var terminalMarks: [String: EditorialTombstone] = [:]
    private var terminalMarksNeedSave = false
    private let tombstoneStorageKey = "TTActualidad.confirmed-terminals.v1"
    @Published private(set) var isManuallyRefreshing = false
    private var lastCompletedRefresh: Date? = nil
    private var currentVisitSnapshot: [String: String]?

    func updateHomeQuickActions() {
        // Use canonical data, excluding provisional optimistic additions.
        // Preserve the previous read on a cold launch or a failed refresh.
        var summary = HomeQuickActions.savedSummary() ?? TTQuickActionSummary()
        if let checkedAt = canonicalSnapshot.updatedAt {
            let current = applyConfirmedTerminals(canonicalSnapshot)
            summary = TTQuickActionSummary(
                newsReady: current.news.count, trendsReady: current.trendListas.count,
                newsWorking: current.newsElaboracion.count,
                trendsWorking: current.trendsElaboracion.count,
                pending: pendingOperationsCount, checkedAt: checkedAt,
                partial: current.partial)
        }
        summary.pending = pendingOperationsCount
        HomeQuickActions.update(summary)
    }

    init() {
        if let saved = UserDefaults.standard.data(forKey: tombstoneStorageKey),
           let tombstones = try? JSONDecoder().decode(
                [String: EditorialTombstone].self, from: saved) {
            terminalMarks = tombstones
        }
        unreviewedNews = Set(UserDefaults.standard.stringArray(
            forKey: "TTActualidad.unread.news.v1") ?? [])
        unreviewedTrends = Set(UserDefaults.standard.stringArray(
            forKey: "TTActualidad.unread.trends.v1") ?? [])
        radarNewNames = Set(UserDefaults.standard.stringArray(
            forKey: "TTActualidad.radar.newNames.v1") ?? [])
        if let stored = UserDefaults.standard.data(forKey: "TTActualidad.operations.v1"),
           let decoded = try? JSONDecoder().decode([EditorialOperation].self, from: stored) {
            operationHistory = Array(decoded.prefix(60))
        }
        for row in operationHistory where
            ["Enviando", "Esperando GitHub", "Pendiente de GitHub"].contains(row.status) &&
            Date().timeIntervalSince(row.createdAt) < 20 * 60 {
            guard let project = row.project, let id = row.eventID,
                  let revision = row.revision, let requestID = row.requestID,
                  !["Nueva noticia", "De tendencia a noticia"].contains(row.kind) else { continue }
            let action = OptimisticEditorialAction(
                project: project, id: id, revision: revision, decision: row.kind,
                title: row.title, rank: 0, requestID: requestID, phase: .uncertain)
            activeEditorialActions[action.key] = action
        }
    }

    private func recordOperation(id: String, title: String, kind: String, status: String,
                                 requestID: String? = nil, project: String? = nil,
                                 eventID: String? = nil, revision: Int? = nil,
                                 detail: String? = nil) {
        if let index = operationHistory.firstIndex(where: { $0.id == id }),
           operationHistory[index].kind != kind && status == "Enviando" {
            // A new action supersedes a stale local order for the same card.
            // Preserve the former request in audit history without allowing it
            // to replace the user's new decision on a late callback.
            let old = operationHistory.remove(at: index)
            operationHistory.insert(EditorialOperation(
                id: old.id + ":superseded:" + (old.requestID ?? UUID().uuidString),
                title: old.title, kind: old.kind, status: "Sustituida",
                createdAt: old.createdAt, requestID: old.requestID,
                project: old.project, eventID: old.eventID, revision: old.revision,
                detail: "Solicitud anterior reemplazada; verificación en GitHub no concluyente."), at: 0)
        }
        if let index = operationHistory.firstIndex(where: { $0.id == id }) {
            operationHistory[index].status = status
            if let requestID { operationHistory[index].requestID = requestID }
            if let project { operationHistory[index].project = project }
            if let eventID { operationHistory[index].eventID = eventID }
            if let revision { operationHistory[index].revision = revision }
            if let detail { operationHistory[index].detail = detail }
        } else {
            operationHistory.insert(EditorialOperation(
                id: id, title: title, kind: kind, status: status,
                createdAt: Date(), requestID: requestID,
                project: project, eventID: eventID, revision: revision,
                detail: detail), at: 0)
        }
        operationHistory = Array(operationHistory.prefix(60))
        if let data = try? JSONEncoder().encode(operationHistory) {
            UserDefaults.standard.set(data, forKey: "TTActualidad.operations.v1")
        }
    }

    private func markTerminal(project: String, id: String, revision: Int,
                              decision: String, at: Date) {
        guard !id.isEmpty, ["ttittulares", "ttendencias"].contains(project),
              ["deleted", "dismissed", "published"].contains(decision) else { return }
        let key = project + ":" + id
        if let earlier = terminalMarks[key] {
            guard revision > earlier.revision ||
                  (revision == earlier.revision && at > earlier.confirmedAt) else { return }
        }
        terminalMarks[key] = EditorialTombstone(
            project: project, id: id, revision: revision,
            decision: decision, confirmedAt: at)
        terminalMarksNeedSave = true
    }

    // Prefer confirmation in the decision ledgers or successful receipts.
    // Never infer a terminal state merely because a row was absent in a
    // single GET response or because an optimistic animation completed.
    private func accumulateConfirmedTerminals(_ docs: [String: [String: Any]],
                                               _ downloaded: [String: Data]) {
        func read(_ path: String, project: String, idKey: String) {
            guard downloaded[path] != nil, let doc = docs[path] else { return }
            for row in Self.rows(doc, "items") {
                let id = Self.str(row, idKey)
                let status = Self.str(row, "status").lowercased()
                guard Self.closed.contains(status) else { continue }
                let date = Self.when(row, [
                    "deleted_at", "dismissed_at", "published_at", "updated_at"
                ]) ?? .distantPast
                markTerminal(project: project, id: id, revision: Self.int(row, "revision"),
                             decision: status, at: date)
            }
        }
        read("ttittulares/decisions.json", project: "ttittulares", idKey: "event_id")
        read("trends/mobile-decisions.json", project: "ttendencias", idKey: "id")
        if downloaded["trends/telegram-manual-explained.json"] != nil,
           let manual = docs["trends/telegram-manual-explained.json"] {
            for row in Self.rows(manual, "items") where
                Self.closed.contains(Self.str(row, "status").lowercased()) {
                markTerminal(project: "ttendencias", id: Self.str(row, "id"),
                             revision: Self.int(row, "revision"),
                             decision: Self.str(row, "status").lowercased(),
                             at: Self.when(row, [
                                "deleted_at", "dismissed_at", "published_at", "updated_at"
                             ]) ?? .distantPast)
            }
        }
        if downloaded["pilot/ttactualidad-action-receipts.json"] != nil,
           let receipts = docs["pilot/ttactualidad-action-receipts.json"] {
            for row in Self.rows(receipts, "items") {
                let status = Self.str(row, "status").lowercased()
                guard ["applied", "already_applied"].contains(status) else { continue }
                let decision = Self.str(row, "decision").lowercased()
                guard ["deleted", "discard", "published"].contains(decision) else { continue }
                markTerminal(project: Self.str(row, "project"),
                             id: Self.str(row, "event_id"),
                             revision: Self.int(row, "revision"),
                             decision: decision == "discard" ? "dismissed" : decision,
                             at: Self.when(row, ["at"]) ?? .distantPast)
            }
        }
        persistTerminals()
    }

    private func persistTerminals() {
        // Avoid encoding and writing a potentially large tombstone ledger on
        // each periodic refresh when GitHub returns no new decisions.
        guard terminalMarksNeedSave else { return }
        if let saved = try? JSONEncoder().encode(terminalMarks) {
            UserDefaults.standard.set(saved, forKey: tombstoneStorageKey)
            terminalMarksNeedSave = false
        }
    }

    private func isTerminal(project: String, id: String, revision: Int) -> Bool {
        guard let tombstone = terminalMarks[project + ":" + id] else { return false }
        return revision <= tombstone.revision
    }

    private func applyConfirmedTerminals(_ original: EditorialSnapshot) -> EditorialSnapshot {
        var clean = original
        clean.news.removeAll {
            isTerminal(project: "ttittulares", id: $0.id, revision: $0.revision)
        }
        clean.newsElaboracion.removeAll {
            isTerminal(project: "ttittulares", id: $0.id, revision: $0.revision)
        }
        clean.newsRevision.removeAll {
            isTerminal(project: "ttittulares", id: $0.id, revision: $0.revision)
        }
        clean.newsCreciendo.removeAll {
            isTerminal(project: "ttittulares", id: $0.id, revision: $0.revision)
        }
        clean.newsTremending.removeAll {
            isTerminal(project: "ttittulares", id: $0.id, revision: $0.revision)
        }
        clean.trendListas.removeAll {
            isTerminal(project: "ttendencias", id: $0.editorialID, revision: $0.revision)
        }
        clean.trendsElaboracion.removeAll {
            isTerminal(project: "ttendencias", id: $0.editorialID, revision: $0.revision)
        }
        clean.unexplainedTrends.removeAll { isTerminal(project: "ttendencias", id: $0.editorialID, revision: $0.revision) }
        clean.top30 = clean.top30.map { item in
            guard isTerminal(project: "ttendencias", id: item.editorialID,
                             revision: item.revision) else { return item }
            return overlayTrend(item, status: "PENDIENTE", inListas: false)
        }
        return clean
    }

    private func storeUnread() {
        UserDefaults.standard.set(Array(unreviewedNews),
                                  forKey: "TTActualidad.unread.news.v1")
        UserDefaults.standard.set(Array(unreviewedTrends),
                                  forKey: "TTActualidad.unread.trends.v1")
    }

    func markNewsReviewed(_ id: String) {
        reviewedNews.insert(id)
        unreviewedNews.remove(id)
        storeUnread()
    }
    func markTrendReviewed(_ name: String) {
        reviewedTrends.insert(name)
        unreviewedTrends.remove(name)
        storeUnread()
    }

    // The radar's 'movement: new' describes an aggregate comparison and may
    // mark a long-existing topic as new. Track actual entrances between
    // complete, distinct radar snapshots this iPhone has seen instead.
    private func updateRadarEntrants(_ recent: [String: Any]) {
        let currentVersion = Self.str(recent, "updated_at")
        guard !currentVersion.isEmpty else { return }
        let current = Set(Self.rows(recent, "items").prefix(30).compactMap {
            let name = Self.str($0, "name").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })
        guard !current.isEmpty else { return }
        let defaults = UserDefaults.standard
        let versionKey = "TTActualidad.radar.lastVersion.v1"
        let namesKey = "TTActualidad.radar.lastNames.v1"
        let newKey = "TTActualidad.radar.newNames.v1"
        if defaults.string(forKey: versionKey) == currentVersion {
            radarNewNames = Set(defaults.stringArray(forKey: newKey) ?? [])
                .intersection(current)
            return
        }
        if let previousNames = defaults.stringArray(forKey: namesKey) {
            radarNewNames = current.subtracting(Set(previousNames))
        } else {
            radarNewNames = [] // First complete sync only establishes baseline.
        }
        defaults.set(currentVersion, forKey: versionKey)
        defaults.set(Array(current), forKey: namesKey)
        defaults.set(Array(radarNewNames), forKey: newKey)
    }
    private var draftNews = [String: NewsItem]()

    // Canonical GitHub editorial sources. Not a Cloudflare or Vercel endpoint.
    private let paths = [
        "pilot/ttactualidad-publication-events.json",
        "pilot/ttactualidad-action-receipts.json",
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

    /// Only one GitHub refresh at a time. Do not queue another entire
    /// 15-file download each time the app changes foreground state.
    func refreshIfStale(minInterval: TimeInterval = 120) async {
        guard !isLoading,
              lastCompletedRefresh.map({ Date().timeIntervalSince($0) >= minInterval }) ?? true
        else { return }
        await refresh()
    }

    // A button must await an already-running download rather than read the
    // previous snapshot when refreshIfStale's exclusivity guard returns early.
    func refreshForEditorialRequest() async {
        if isLoading {
            while isLoading {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        } else {
            await refreshIfStale(minInterval: 0)
        }
    }

    func refresh(manual: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        if manual { isManuallyRefreshing = true }
        defer {
            isLoading = false
            isManuallyRefreshing = false
            lastCompletedRefresh = Date()
            updateHomeQuickActions()
        }
        // The 14 remote documents may contain megabytes of JSON. Their
        // validation, disk writes and parsing must not run on MainActor:
        // doing so freezes tab transitions for 1-2 seconds during refresh.
        let loaded = await EditorialDocumentLoader.load(paths: paths)
        let downloaded = loaded.downloaded
        let docs = loaded.docs
        let partial = loaded.partial
        editorialReadFreshness = [
            "ttittulares": ["ttittulares/editorial-queue.json", "ttittulares/prepared.json",
                            "ttittulares/decisions.json"].allSatisfy { downloaded[$0] != nil },
            "ttendencias": ["trends/editorial-queue.json", "trends/requests.json",
                            "trends/telegram-manual-explained.json", "trends/mobile-decisions.json"]
                .allSatisfy { downloaded[$0] != nil }
        ]

        updatePublicationEvents(
            ledger: downloaded["pilot/ttactualidad-publication-events.json"] != nil ?
                docs["pilot/ttactualidad-publication-events.json"] : nil,
            receipts: downloaded["pilot/ttactualidad-action-receipts.json"] != nil ?
                docs["pilot/ttactualidad-action-receipts.json"] : nil)
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
        // Archive photographs and verified Sites PNGs are separate catalogs.
        async let archivePhotosTask = ArchivePhotoCatalog.load()
        async let siteImagesTask = SiteAIImageCatalog.load()
        let archivePhotos = await archivePhotosTask
        let siteImages = await siteImagesTask
        let news = Self.buildNews(prepared: docs["ttittulares/prepared.json"]!,
                                  decisions: docs["ttittulares/decisions.json"]!,
                                  archivePhotos: archivePhotos)
        let ready = Self.buildTrendListas(
            manual: docs["trends/telegram-manual-explained.json"]!,
            requests: docs["trends/requests.json"]!,
            deliveries: docs["trends/telegram-image-deliveries.json"]!,
            decisions: docs["trends/mobile-decisions.json"]!,
            queue: docs["trends/editorial-queue.json"]!,
            now: now, archivePhotos: archivePhotos, siteImages: siteImages
        )
        let top = Self.buildTop30(
            recent: docs["trends/recent.json"] ?? [:],
            manual: docs["trends/telegram-manual-explained.json"]!,
            explained: docs["trends/explained.json"] ?? [:],
            requests: docs["trends/requests.json"]!,
            ready: ready, archivePhotos: archivePhotos, siteImages: siteImages
        )
        let unexplained = Self.buildUnexplainedTrends(
            requests: docs["trends/requests.json"]!,
            decisions: docs["trends/mobile-decisions.json"]!, now: now)
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
        // A valid empty queue is authoritative. Falling back merely because
        // it is empty resurrects a stale status.json after the run finishes.
        let readyRevisions = Dictionary(news.map { ($0.id, $0.revision) },
                                        uniquingKeysWith: max)
        let workingRows = EditorialProgressPolicy.workingNewsRows(
            queue: newsQueue["items"] is [[String: Any]] ? processing : nil,
            fallback: Self.rows(status, "processing_items"), readyRevisions: readyRevisions)
        let queueNews = sectionNews(workingRows, "EN ELABORACIÓN")
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
            manual: docs["trends/telegram-manual-explained.json"]!,
            decisions: docs["trends/mobile-decisions.json"]!,
            ready: ready
        )
        accumulateConfirmedTerminals(docs, downloaded)
        canonicalSnapshot = applyConfirmedTerminals(EditorialSnapshot(
                                     news: news, newsElaboracion: queueNews,
                                     newsRevision: problematic, newsCreciendo: growing,
                                     newsTremending: trending,
                                     top30: top, trendListas: ready, trendsElaboracion: trendsQueued,
                                     unexplainedTrends: unexplained,
                                     updatedAt: now, partial: partial,
                                     oneSourceCount: status["one_source_count"] as? Int,
                                     twoSourceCount: status["two_source_count"] as? Int,
                                     oneSourceDelta: status["one_source_delta"] as? Int,
                                     twoSourceDelta: status["two_source_delta"] as? Int,
                                     radarAt: Self.when(status, ["radar_at"]),
                                     trendsRadarAt: Self.when(docs["trends/recent.json"] ?? [:],
                                                              ["captured_at"]),
                                     trendsRadarReliability: Self.str(docs["trends/recent.json"] ?? [:],
                                                                      "reliability")))
        if !partial && downloaded.count == paths.count {
            updateRadarEntrants(docs["trends/recent.json"] ?? [:])
            updateNovedades(news: canonicalSnapshot.news,
                            trends: canonicalSnapshot.trendListas,
                            top30: canonicalSnapshot.top30,
                            newsWorking: canonicalSnapshot.newsElaboracion,
                            trendsWorking: canonicalSnapshot.trendsElaboracion)
        }
        // A fresh terminal decision may be applied even if an unrelated
        // source timed out. Do not keep yesterday's optimistic elaboration
        // while GitHub already confirms today's deletion.
        // News receipts must be reconciled even when the unrelated trends
        // radar is temporarily unavailable. Legacy iOS builds had no request ID.
        let freshReceipts = downloaded["pilot/ttactualidad-action-receipts.json"] != nil
        let freshNewsDecisions = downloaded["ttittulares/decisions.json"] != nil
        let freshTrendClosures = downloaded["trends/telegram-manual-explained.json"] != nil &&
                                 downloaded["trends/mobile-decisions.json"] != nil
        if freshReceipts || freshNewsDecisions || freshTrendClosures {
            reconcileOperationHistory(
                receipts: freshReceipts ?
                    docs["pilot/ttactualidad-action-receipts.json"] ?? [:] : [:],
                newsDecisions: freshNewsDecisions ?
                    docs["ttittulares/decisions.json"] ?? [:] : [:],
                manual: freshTrendClosures ?
                    docs["trends/telegram-manual-explained.json"] ?? [:] : [:],
                requests: freshTrendClosures ?
                    docs["trends/requests.json"] ?? [:] : [:],
                decisions: freshTrendClosures ?
                    docs["trends/mobile-decisions.json"] ?? [:] : [:])
            if freshTrendClosures {
                retireClosedTrendOverlays(
                    manual: docs["trends/telegram-manual-explained.json"] ?? [:],
                    requests: docs["trends/requests.json"] ?? [:],
                    decisions: docs["trends/mobile-decisions.json"] ?? [:])
            }
        }
        // Stale local deletion/rework cannot monopolize a READY card forever.
        // Require fresh copies of all four relevant GitHub documents.
        if downloaded["ttittulares/prepared.json"] != nil &&
           downloaded["ttittulares/editorial-queue.json"] != nil &&
           downloaded["pilot/ttactualidad-action-receipts.json"] != nil &&
           downloaded["ttittulares/decisions.json"] != nil {
            retireAbandonedNewsOperations(
                ready: docs["ttittulares/prepared.json"] ?? [:],
                queue: docs["ttittulares/editorial-queue.json"] ?? [:],
                receipts: docs["pilot/ttactualidad-action-receipts.json"] ?? [:],
                decisions: docs["ttittulares/decisions.json"] ?? [:])
        }
        // Only these THREE authoritative files need to be fresh to release an
        // inactive trend; unrelated radar/archive timeouts must not block it.
        if downloaded["trends/requests.json"] != nil &&
           downloaded["trends/editorial-queue.json"] != nil &&
           downloaded["pilot/ttactualidad-action-receipts.json"] != nil {
            retireAbandonedTrendOperations(requests: docs["trends/requests.json"] ?? [:],
                                           queue: docs["trends/editorial-queue.json"] ?? [:])
        }
        // A grouped explanation closes every member's request, even though
        // only the leader gets a separate card in Listas. Do not leave local
        // optimistic "En elaboración" overlays over confirmed explanations.
        if downloaded["trends/requests.json"] != nil {
            retireExplainedTrendActions(requests: docs["trends/requests.json"] ?? [:])
        }
        if !partial && downloaded.count == paths.count {
            retireSyncedActions()
            retireSyncedDrafts()
        }
        applyOptimisticOverlay()
        message = partial ? "Datos parciales o en caché" : "Datos consultados directamente en GitHub"
        if fresh {
            await publishLiveCounts(checkedAt: now,
                                    partial: partial || pendingOperationsCount > 0)
        }
    }

    // This function is intentionally independent of the complete radar read.
    // GitHub may confirm several publishes while some unrelated source times
    // out; never let a stale response replace newly confirmed publication IDs.
    private func updatePublicationEvents(ledger: [String: Any]?,
                                         receipts: [String: Any]?) {
        guard ledger != nil || receipts != nil else { return }
        var unique: [String: PublicationEvent] = [:]
        let oldest = Date().addingTimeInterval(-8 * 86_400)
        for event in publicationEvents where event.confirmedAt >= oldest {
            unique[event.project + ":" + event.eventID + ":r" +
                   String(event.revision)] = event
        }
        func collect(_ items: [[String: Any]], isReceipt: Bool) {
            for row in items {
                if isReceipt {
                    guard Self.str(row, "decision") == "published" &&
                          ["applied", "already_applied"].contains(
                              Self.str(row, "status").lowercased()) else { continue }
                }
                guard let at = Self.when(row, ["at"]), at >= oldest else { continue }
                let project = Self.str(row, "project")
                let id = Self.str(row, "event_id")
                let revision = Self.int(row, "revision")
                guard ["ttittulares", "ttendencias"].contains(project),
                      !id.isEmpty else { continue }
                let key = project + ":" + id + ":r" + String(revision)
                // Retain the actual first GitHub-confirmed timestamp.
                if let old = unique[key], old.confirmedAt <= at { continue }
                unique[key] = PublicationEvent(
                    project: project, eventID: id,
                    revision: revision, confirmedAt: at)
            }
        }
        if let ledger { collect(Self.rows(ledger, "items"), isReceipt: false) }
        if let receipts { collect(Self.rows(receipts, "items"), isReceipt: true) }
        publicationEvents = Array(unique.values)
        publicationLedgerAvailable = true
    }

    private func fetchPublicationJSON(_ path: String) async -> [String: Any]? {
        let nonce = String(Int(Date().timeIntervalSince1970 * 1000))
        guard let url = URL(string:
            "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/" +
            path + "?pub=" + nonce) else { return nil }
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 12)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch {
            return nil
        }
    }

    /// Light, invisible refresh after GitHub verifies a published item.
    /// Does not touch the loading spinner, scroll position or radar cards.
    func refreshPublicationCounters(expectedProject: String? = nil,
                                    expectedID: String? = nil,
                                    expectedRevision: Int? = nil) async {
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            async let ledger = fetchPublicationJSON(
                "pilot/ttactualidad-publication-events.json")
            async let receipts = fetchPublicationJSON(
                "pilot/ttactualidad-action-receipts.json")
            updatePublicationEvents(ledger: await ledger, receipts: await receipts)
            guard let project = expectedProject, let id = expectedID,
                  let revision = expectedRevision else { break }
            if publicationEvents.contains(where: {
                $0.project == project && $0.eventID == id && $0.revision == revision
            }) { break }
        }
    }

    // GitHub's receipt is authoritative. Rendering a provisional change
    // must NEVER become a success merely because it disappeared locally.
    // Legacy 0.4.x operations stored only "project:id:rN" and had no
    // request UUID. Recover identity for BOTH projects before reconciling.
    private func operationIdentity(_ operation: EditorialOperation)
        -> (project: String, eventID: String, revision: Int)? {
        if let project = operation.project, let id = operation.eventID,
           let revision = operation.revision, !id.isEmpty {
            return (project, id, revision)
        }
        let raw = operation.id
        guard let prefix = raw.firstIndex(of: ":"),
              let revisionMark = raw.range(of: ":r", options: .backwards),
              revisionMark.lowerBound > prefix,
              let revision = Int(raw[revisionMark.upperBound...]) else { return nil }
        let project = String(raw[..<prefix])
        guard ["ttittulares", "ttendencias"].contains(project) else { return nil }
        let id = String(raw[raw.index(after: prefix)..<revisionMark.lowerBound])
        guard !id.isEmpty else { return nil }
        return (project, id, revision)
    }

    private func reconcileOperationHistory(receipts: [String: Any],
                                           newsDecisions: [String: Any],
                                           manual: [String: Any],
                                           requests: [String: Any],
                                           decisions: [String: Any]) {
        let closedTrends = Self.closedTrends(manual: manual, requests: requests,
                                             decisions: decisions)
        let remote = Self.rows(receipts, "items")
        let newsClosures = Self.rows(newsDecisions, "items")
        let readyNews = canonicalSnapshot.news
        let workingNews = canonicalSnapshot.newsElaboracion
        let readyTrends = canonicalSnapshot.trendListas
        let workingTrends = canonicalSnapshot.trendsElaboracion

        for operation in operationHistory where
            !["Rechazada", "Retirada", "Caducada", "Sustituida", "Explicada"].contains(operation.status) {
            guard let identity = operationIdentity(operation) else { continue }
            let id = identity.eventID
            let isTrend = identity.project == "ttendencias"
            let operationTime = operation.createdAt.addingTimeInterval(-180)
            // An exact request_id always takes precedence. When absent (IPA
            // 0.4.3 and older), use the full project/event/revision/decision
            // combination and require a receipt not older than the action.
            let receipt = remote
                .filter { row in
                    if let requestID = operation.requestID, !requestID.isEmpty {
                        return Self.str(row, "request_id") == requestID
                    }
                    return Self.str(row, "project") == identity.project &&
                           Self.str(row, "event_id") == id &&
                           Self.int(row, "revision") == identity.revision &&
                           Self.str(row, "decision") == operation.kind &&
                           (Self.when(row, ["at"]) ?? .distantPast) >= operationTime
                }
                .max {
                    (Self.when($0, ["at"]) ?? .distantPast) <
                    (Self.when($1, ["at"]) ?? .distantPast)
                }
            let receiptStatus = receipt.map { Self.str($0, "status").lowercased() } ?? ""
            let accepted = ["applied", "already_applied"].contains(receiptStatus)

            let closure = newsClosures.first { row in
                Self.str(row, "event_id") == id &&
                (Self.when(row, ["updated_at", "deleted_at"]) ?? .distantPast) >= operationTime &&
                (operation.kind == "deleted" ?
                    Self.str(row, "status").lowercased() == "deleted" : false)
            }
            let confirmed = accepted || closure != nil
            let newsTerminal = !isTrend && newsClosures.contains { row in
                Self.str(row, "event_id") == id &&
                ["deleted", "dismissed", "published"].contains(
                    Self.str(row, "status").lowercased()) &&
                Self.int(row, "revision") >= identity.revision
            }
            let closedAfterRequest = isTrend &&
                closedTrends.isClosed(id: id, name: operation.title,
                                     since: operation.createdAt)
            let stage: String
            if closedAfterRequest || newsTerminal {
                stage = "Retirada"
            } else if ["Nueva noticia", "De tendencia a noticia"].contains(operation.kind) {
                if readyNews.contains(where: { $0.id == id }) { stage = "En Listas" }
                else if workingNews.contains(where: { $0.id == id }) {
                    stage = "En elaboración"
                } else if confirmed { stage = "En elaboración" }
                else { stage = outstandingStage(for: operation) }
            } else if ["rework", "prepare", "hints"].contains(operation.kind) {
                let old = identity.revision
                let finished = isTrend
                    ? readyTrends.contains(where: {
                        $0.editorialID == id && $0.revision > old
                    })
                    : readyNews.contains(where: { $0.id == id && $0.revision > old })
                let working = isTrend
                    ? workingTrends.contains(where: {
                        $0.editorialID == id && $0.revision >= old
                    })
                    : workingNews.contains(where: { $0.id == id && $0.revision >= old })
                if finished { stage = "En Listas" }
                else if confirmed || working { stage = "En elaboración" }
                else { stage = outstandingStage(for: operation) }
            } else if confirmed {
                stage = "Confirmada"
            } else if ["failed", "rejected"].contains(receiptStatus) {
                stage = "Rechazada"
            } else {
                stage = outstandingStage(for: operation)
            }
            if stage != operation.status {
                recordOperation(id: operation.id, title: operation.title,
                                kind: operation.kind, status: stage,
                                requestID: operation.requestID ??
                                    (receipt.map { Self.str($0, "request_id") }),
                                project: identity.project, eventID: id,
                                revision: identity.revision,
                                detail: confirmed ? "Confirmado en GitHub" : nil)
            }
            if stage == "Retirada" || stage == "Confirmada" ||
               stage == "En Listas" || stage == "Rechazada" {
                activeEditorialActions.removeValue(forKey: operation.id)
            } else if confirmed, var action = activeEditorialActions[operation.id] {
                action.phase = .confirmed
                activeEditorialActions[operation.id] = action
            }
        }
    }

    // An unconfirmed iPhone order is not an indefinite lock. Only retire it
    // when the fresh authoritative files STILL show the exact same READY card,
    // no editorial work is active, and GitHub has no matching receipt.
    private func retireAbandonedNewsOperations(ready: [String: Any],
                                               queue: [String: Any],
                                               receipts: [String: Any],
                                               decisions: [String: Any]) {
        let readyRows = Self.rows(ready, "items")
        let activeRows = Self.rows(queue, "items")
        let receiptRows = Self.rows(receipts, "items")
        let terminals = Self.rows(decisions, "items")
        for operation in operationHistory where
            operation.project == "ttittulares" &&
            (operation.isOutstanding || operation.status == "En elaboración") &&
            !operation.id.contains(":superseded:") {
            guard let identity = operationIdentity(operation) else { continue }
            let id = identity.eventID
            if terminals.contains(where: {
                Self.str($0, "event_id") == id &&
                Self.int($0, "revision") >= identity.revision &&
                ["published", "deleted", "dismissed"].contains(
                    Self.str($0, "status").lowercased())
            }) {
                recordOperation(id: operation.id, title: operation.title,
                                kind: operation.kind, status: "Retirada",
                                detail: "GitHub confirma la decisión final sobre esta noticia.")
                activeEditorialActions.removeValue(forKey: operation.id)
                continue
            }
            guard Date().timeIntervalSince(operation.createdAt) > 12 * 60,
                  readyRows.contains(where: {
                      Self.str($0, "event_id") == id &&
                      Self.int($0, "revision") == identity.revision
                  }),
                  !activeRows.contains(where: {
                      Self.str($0, "event_id") == id &&
                      ["PROCESSING", "UPDATE_PROCESSING"].contains(Self.str($0, "status"))
                  }),
                  !receiptRows.contains(where: {
                      if let requestID = operation.requestID, !requestID.isEmpty {
                          return Self.str($0, "request_id") == requestID
                      }
                      return Self.str($0, "project") == "ttittulares" &&
                          Self.str($0, "event_id") == id &&
                          Self.int($0, "revision") == identity.revision &&
                          Self.str($0, "decision") == operation.kind
                  }) else { continue }
            recordOperation(id: operation.id, title: operation.title,
                            kind: operation.kind, status: "Caducada",
                            detail: "Sin comprobante de GitHub; la noticia sigue en Listas. Ya puedes intentarlo de nuevo.")
            activeEditorialActions.removeValue(forKey: operation.id)
        }
    }

    // Expire only obsolete local trend operations after a COMPLETE fresh read.
    // Never expire an active GitHub queue entry or assume an API timeout failed.
    private func retireAbandonedTrendOperations(requests: [String: Any],
                                                queue: [String: Any]) {
        let authoritative = Self.rows(requests, "requests")
        let activeQueue = Self.rows(queue, "items")
        for operation in operationHistory where
            operation.project == "ttendencias" &&
            ["prepare", "rework", "hints"].contains(operation.kind) &&
            ["Enviando", "Esperando GitHub", "Pendiente de GitHub",
             "Sin confirmar", "En elaboración"].contains(operation.status) &&
            Date().timeIntervalSince(operation.createdAt) > 20 * 60 {
            guard let identity = operationIdentity(operation),
                  let id = Optional(identity.eventID),
                  let revision = Optional(identity.revision),
                  let server = authoritative.first(where: {
                      Self.str($0, "id") == id && Self.int($0, "revision") == revision
                  }),
                  ["inactive", "problem", "failed"].contains(
                      Self.str(server, "status").lowercased()),
                  !activeQueue.contains(where: {
                      Self.str($0, "id") == id &&
                      ["preparing", "update"].contains(Self.str($0, "status").lowercased())
                  }) else { continue }
            recordOperation(id: operation.id, title: operation.title,
                            kind: operation.kind, status: "Caducada",
                            detail: "GitHub confirma que ya no hay elaboración activa. Puedes enviar otra orden.")
            activeEditorialActions.removeValue(forKey: operation.id)
        }
    }

    // Clears orphaned in-memory optimistic reworks even when their local
    // operation was recorded in an older build without a request_id.
    // Only a freshly downloaded request with a verifiable explanation may
    // retire the matching iPhone action. A completed group member need not
    // have its own card in telegram-manual-explained.json or Listas.
    private func retireExplainedTrendActions(requests: [String: Any]) {
        let rows = Self.rows(requests, "requests")
        for (key, action) in activeEditorialActions where
            action.project == "ttendencias" &&
            ["prepare", "rework", "hints"].contains(action.decision) {
            guard let operation = operationHistory.first(where: { $0.id == key }) else {
                continue
            }
            let minimumRevision = action.revision +
                (["rework", "hints"].contains(action.decision) ? 1 : 0)
            guard let finished = rows.filter({
                Self.str($0, "id") == action.id &&
                Self.int($0, "revision") >= minimumRevision &&
                ["explained", "published"].contains(Self.str($0, "status").lowercased()) &&
                !Self.str($0, "explanation").isEmpty &&
                (Self.when($0, ["explained_at"]) ?? .distantPast) >=
                    operation.createdAt.addingTimeInterval(-180)
            }).max(by: { Self.int($0, "revision") < Self.int($1, "revision") })
            else { continue }
            let grouped = !Self.str(finished, "group_leader_id").isEmpty &&
                Self.str(finished, "group_leader_id") != action.id
            activeEditorialActions.removeValue(forKey: key)
            recordOperation(id: key, title: action.title, kind: action.decision,
                            status: "Explicada", requestID: action.requestID,
                            project: action.project, eventID: action.id,
                            revision: action.revision,
                            detail: grouped ?
                                "Explicación agrupada confirmada en GitHub." :
                                "Explicación confirmada en GitHub.")
        }
    }

    private func retireClosedTrendOverlays(manual: [String: Any],
                                           requests: [String: Any],
                                           decisions: [String: Any]) {
        let closures = Self.closedTrends(manual: manual, requests: requests,
                                         decisions: decisions)
        for (key, action) in activeEditorialActions where
            action.project == "ttendencias" &&
            closures.isClosed(id: action.id, name: action.title,
                              since: operationHistory.first(where: {
                                  $0.id == key
                              })?.createdAt ?? .distantPast) {
            activeEditorialActions.removeValue(forKey: key)
            if let old = operationHistory.first(where: { $0.id == key }) {
                recordOperation(id: old.id, title: old.title, kind: old.kind,
                                status: "Retirada")
            }
        }
    }

    private func outstandingStage(for operation: EditorialOperation) -> String {
        if ["Confirmada", "En Listas", "Rechazada", "Retirada"].contains(operation.status) {
            return operation.status
        }
        if operation.status == "En elaboración" { return operation.status }
        if Date().timeIntervalSince(operation.createdAt) > 10 * 60 {
            return "Sin confirmar"
        }
        return "Esperando GitHub"
    }

    // +Noticia appears immediately in En elaboración. The real queue is still
    // committed asynchronously by GitHub Actions, and verified independently.
    func beginManualNews(requestID: String, title: String, url: String,
                         fromTrend: Bool = false) {
        let eventID = "manual-" + requestID
        let placeholder = NewsItem(id: eventID, title: title.isEmpty ? url : title,
                                   text: "Solicitud editorial pendiente de confirmación",
                                   publishedAt: Date(), revision: 1,
                                   sourceURL: URL(string: url), imageURL: nil,
                                   factual: "", closer: "", sources: 0,
                                   status: "EN ELABORACIÓN")
        draftNews[requestID] = placeholder
        recordOperation(id: eventID, title: placeholder.title,
                        kind: fromTrend ? "De tendencia a noticia" : "Nueva noticia",
                        status: "Enviando", requestID: requestID,
                        project: "ttittulares", eventID: eventID, revision: 1,
                        detail: "Destino: En elaboración → Listas")
        actionMessage = "Noticia añadida provisionalmente a En elaboración · guardando en GitHub…"
        actionIsError = false
        applyOptimisticOverlay()
    }

    func completeManualNews(requestID: String, result: GitHubEditor.WriteResult,
                            detail: String) {
        switch result {
        case .verified:
            let manualID = "manual-" + requestID
            let kind = operationHistory.first(where: { $0.id == manualID })?.kind ?? "Nueva noticia"
            recordOperation(id: manualID, title: draftNews[requestID]?.title ?? "Noticia",
                            kind: kind, status: "En elaboración")
            actionMessage = "Noticia confirmada en GitHub · sincronizando automáticamente"
            actionIsError = false
            Task { await self.refreshIfStale(minInterval: 0) }
        case .pending:
            recordOperation(id: "manual-" + requestID, title: draftNews[requestID]?.title ?? "Noticia",
                            kind: "Nueva noticia", status: "Esperando GitHub")
            actionMessage = "GitHub aún está procesando la noticia. Se mantiene en En elaboración."
            actionIsError = false
            Task { await self.refreshIfStale(minInterval: 30) }
        case .failed:
            recordOperation(id: "manual-" + requestID, title: draftNews[requestID]?.title ?? "Noticia",
                            kind: "Nueva noticia", status: "Rechazada")
            draftNews.removeValue(forKey: requestID)
            actionMessage = "No se pudo añadir la noticia: " + detail
            actionIsError = true
        }
        applyOptimisticOverlay()
    }

    private func retireSyncedDrafts() {
        let authoritativeIDs = Set(canonicalSnapshot.newsElaboracion.map(\.id) +
                                   canonicalSnapshot.news.map(\.id))
        for (id, draft) in draftNews where
            authoritativeIDs.contains(draft.id) ||
            terminalMarks["ttittulares:" + draft.id] != nil {
            draftNews.removeValue(forKey: id)
        }
    }

    // A local action instantly changes ALL views using the shared store.
    // The operation is not marked verified until GitHub supplies its receipt.
    func beginEditorialAction(project: String, id: String, revision: Int, decision: String,
                              title: String, rank: Int, requestID: String) -> Bool {
        guard !id.isEmpty, revision >= 0 else {
            actionMessage = "No hay identificador editorial válido: actualiza la información."
            actionIsError = true
            return false
        }
        let action = OptimisticEditorialAction(project: project, id: id,
                                               revision: revision, decision: decision,
                                               title: title, rank: rank, requestID: requestID)
        guard !isActionInProgress(project: project, id: id, revision: revision) else {
            actionMessage = "Esta orden ya está en curso; no es necesario repetirla."
            actionIsError = false
            return false
        }
        activeEditorialActions[action.key] = action
        recordOperation(id: action.key, title: title, kind: decision, status: "Enviando",
                        requestID: requestID, project: project, eventID: id,
                        revision: revision,
                        detail: decision == "published" ?
                                    "Publicado: retirar de Listas y contabilizar tras confirmar" :
                                decision == "deleted" ? "No publicado: retirar de Listas" :
                                decision == "discard" ? "Destino: Desestimadas" :
                                "Destino: En elaboración → Listas")
        actionMessage = decision == "deleted" ? "Retirado de la vista · guardando en GitHub…" :
                        decision == "discard" ? "Supresión solicitada · guardando en GitHub…" :
                        "Trasladado a elaboración · guardando en GitHub…"
        actionIsError = false
        applyOptimisticOverlay()
        refreshOptimisticActivity()
        return true
    }

    func isActionInProgress(project: String, id: String, revision: Int) -> Bool {
        activeEditorialActions[project + ":" + id + ":r" + String(revision)] != nil ||
        operationHistory.contains {
            $0.project == project && $0.eventID == id && $0.revision == revision &&
            ["Enviando", "Esperando GitHub", "Pendiente de GitHub", "Sin confirmar"].contains($0.status)
        }
    }

    func completeEditorialAction(project: String, id: String, revision: Int,
                                 requestID: String, result: GitHubEditor.WriteResult, detail: String) {
        let key = project + ":" + id + ":r" + String(revision)
        // The user may have removed a completed item while an older rework
        // is still being confirmed. The late callback cannot resurrect it.
        if operationHistory.contains(where: { $0.id == key && $0.status == "Retirada" }) {
            activeEditorialActions.removeValue(forKey: key)
            applyOptimisticOverlay()
            refreshOptimisticActivity()
            return
        }
        // A superseded HTTP dispatch must never overwrite a newer action
        // for the same news revision on delayed network completion.
        guard var action = activeEditorialActions[key],
              action.requestID == requestID else { return }
        switch result {
        case .verified:
            // A successful direct receipt verification is sufficient proof to
            // persist the tombstone immediately, before any GitHub CDN reads.
            if ["deleted", "discard", "published"].contains(action.decision) {
                markTerminal(project: project, id: id, revision: revision,
                             decision: action.decision == "discard" ? "dismissed" :
                                       action.decision, at: Date())
                persistTerminals()
            }
            recordOperation(id: key, title: action.title, kind: action.decision,
                            status: ["prepare", "rework", "hints"].contains(action.decision) ?
                                    "En elaboración" : "Confirmada")
            action.phase = .confirmed
            activeEditorialActions[key] = action
            actionMessage = "Verificado en GitHub: " + action.title
            actionIsError = false
            // The exact GitHub action receipt is already verified here.
            // Count it NOW, without waiting for raw GitHub CDN propagation.
            // The precise backend timestamp replaces this fallback on sync.
            if action.decision == "published",
               !publicationEvents.contains(where: {
                   $0.project == project && $0.eventID == id && $0.revision == revision
               }) {
                publicationEvents.append(PublicationEvent(
                    project: project, eventID: id, revision: revision,
                    confirmedAt: Date()))
                publicationLedgerAvailable = true
            }
            // Refresh the published counter independently, without showing
            // a full-page spinner or interrupting interaction.
            Task {
                if action.decision == "published" {
                    await self.refreshPublicationCounters(
                        expectedProject: project, expectedID: id,
                        expectedRevision: revision)
                }
                await self.refreshIfStale(minInterval: 0)
            }
        case .pending:
            recordOperation(id: key, title: action.title, kind: action.decision,
                            status: "Esperando GitHub")
            action.phase = .uncertain
            activeEditorialActions[key] = action
            actionMessage = "Pendiente de confirmar en GitHub: " + action.title +
                            ". La vista conserva el cambio provisional."
            actionIsError = false
            Task { await self.refreshIfStale(minInterval: 30) }
        case .failed:
            recordOperation(id: key, title: action.title, kind: action.decision,
                            status: "Rechazada")
            activeEditorialActions.removeValue(forKey: key)
            actionMessage = "No se pudo aplicar «" + action.title + "»: " + detail
            actionIsError = true
            // Reconstruct all lists from the original canonical state.
        }
        applyOptimisticOverlay()
        refreshOptimisticActivity()
    }

    // Reconciliation uses a complete current GitHub snapshot; partial cached
    // reads never undo an action that was visibly removed moments earlier.
    private func retireSyncedActions() {
        for (key, action) in activeEditorialActions {
            if operationHistory.contains(where: {
                $0.id == key && ["Retirada", "Rechazada"].contains($0.status)
            }) {
                activeEditorialActions.removeValue(forKey: key)
                continue
            }
            guard action.phase != .sending else { continue }
            let originalNews: [NewsItem] = canonicalSnapshot.news +
                canonicalSnapshot.newsElaboracion + canonicalSnapshot.newsRevision +
                canonicalSnapshot.newsCreciendo + canonicalSnapshot.newsTremending
            if action.project == "ttittulares" {
                let stillOriginal = originalNews.contains {
                    $0.id == action.id && $0.revision == action.revision
                }
                if action.decision == "prepare" || action.decision == "rework" {
                    let readyRevision = canonicalSnapshot.news.filter { $0.id == action.id }
                        .map(\.revision).max()
                    if EditorialProgressPolicy.finishedNewsAction(
                        decision: action.decision, originalRevision: action.revision,
                        readyRevision: readyRevision) || canonicalSnapshot.newsElaboracion.contains(where: {
                        $0.id == action.id &&
                        $0.revision >= action.revision + (action.decision == "rework" ? 1 : 0)
                    }) {
                        activeEditorialActions.removeValue(forKey: key)
                    }
                } else if !stillOriginal {
                    activeEditorialActions.removeValue(forKey: key)
                }
            } else if action.decision == "deleted" {
                if !canonicalSnapshot.trendListas.contains(where: {
                    $0.editorialID == action.id && $0.revision == action.revision
                }) {
                    activeEditorialActions.removeValue(forKey: key)
                }
            } else if ["rework", "prepare", "hints"].contains(action.decision) {
                let newWorking = canonicalSnapshot.trendsElaboracion.contains {
                    ($0.editorialID == action.id && $0.revision > action.revision) ||
                    ($0.name == action.title && $0.status == "EN ELABORACIÓN")
                }
                if newWorking { activeEditorialActions.removeValue(forKey: key) }
            } else if action.decision == "discard" {
                if !canonicalSnapshot.trendsElaboracion.contains(where: {
                    $0.editorialID == action.id && $0.revision == action.revision
                }) { activeEditorialActions.removeValue(forKey: key) }
            }
        }
    }

    private func overlayTrend(_ trend: TrendItem, status: String? = nil,
                              inListas: Bool? = nil) -> TrendItem {
        TrendItem(id: trend.id, rank: trend.rank, name: trend.name,
                  explanation: trend.explanation, lastExplained: trend.lastExplained,
                  status: status ?? trend.status, inListas: inListas ?? trend.inListas,
                  editorialID: trend.editorialID, revision: trend.revision,
                  imageURL: trend.imageURL, sourceURL: trend.sourceURL,
                  siteImageURL: trend.siteImageURL,
                  rankDelta: trend.rankDelta, movement: trend.movement,
                  enteredAt: trend.enteredAt, problemReason: trend.problemReason,
                  coveredByID: trend.coveredByID, coveredByName: trend.coveredByName,
                  isJointGroup: trend.isJointGroup, lastReviewed: trend.lastReviewed,
                  reviewOutcome: trend.reviewOutcome, reviewReason: trend.reviewReason,
                  siteImageEditorialID: trend.siteImageEditorialID,
                  siteImageRevision: trend.siteImageRevision,
                  siteImageExplainedAt: trend.siteImageExplainedAt)
    }

    private func overlayNews(_ item: NewsItem, status: String) -> NewsItem {
        NewsItem(id: item.id, title: item.title, text: item.text,
                 publishedAt: item.publishedAt, revision: item.revision,
                 sourceURL: item.sourceURL, imageURL: item.imageURL,
                 factual: item.factual, closer: item.closer, sources: item.sources,
                 status: status)
    }

    private func applyOptimisticOverlay() {
        var updated = canonicalSnapshot
        for draft in draftNews.values where !updated.newsElaboracion.contains(where: {
            $0.id == draft.id
        }) {
            updated.newsElaboracion.insert(draft, at: 0)
        }
        for action in activeEditorialActions.values {
            let sameNews: (NewsItem) -> Bool = {
                $0.id == action.id && $0.revision == action.revision
            }
            let sameTrend: (TrendItem) -> Bool = {
                $0.editorialID == action.id && $0.revision == action.revision
            }
            if action.project == "ttittulares" {
                if ["deleted", "discard", "published"].contains(action.decision) {
                    updated.news.removeAll(where: sameNews)
                    updated.newsElaboracion.removeAll(where: sameNews)
                    updated.newsRevision.removeAll(where: sameNews)
                    updated.newsCreciendo.removeAll(where: sameNews)
                    updated.newsTremending.removeAll(where: sameNews)
                } else if action.decision == "prepare" || action.decision == "rework" {
                    let source = (updated.news + updated.newsRevision +
                                  updated.newsCreciendo).first(where: sameNews)
                    updated.news.removeAll(where: sameNews)
                    updated.newsRevision.removeAll(where: sameNews)
                    updated.newsCreciendo.removeAll(where: sameNews)
                    if let source, !updated.newsElaboracion.contains(where: {
                        $0.id == action.id && $0.revision >= action.revision
                    }) {
                        // A fresh investigation MUST NOT display the previous
                        // factual text, previous gag or archive photo.
                        updated.newsElaboracion.insert(
                            NewsItem(id: source.id, title: source.title,
                                     text: "Nueva investigación solicitada a GitHub",
                                     publishedAt: Date(),
                                     revision: source.revision + (action.decision == "rework" ? 1 : 0),
                                     sourceURL: source.sourceURL, imageURL: nil,
                                     factual: "", closer: "", sources: source.sources,
                                     status: "EN ELABORACIÓN"), at: 0)
                    }
                }
            } else {
                if ["deleted", "discard", "published", "rework", "prepare", "hints"].contains(action.decision) {
                    updated.trendListas.removeAll(where: sameTrend)
                    if ["discard", "deleted", "published"].contains(action.decision) {
                        updated.trendsElaboracion.removeAll(where: sameTrend)
                    }
                }
                updated.top30 = updated.top30.map { original in
                    guard original.name == action.title ||
                          original.editorialID == action.id else { return original }
                    if action.decision == "deleted" ||
                       action.decision == "published" {
                        return overlayTrend(original, inListas: false)
                    }
                    if ["rework", "prepare", "hints"].contains(action.decision) {
                        return overlayTrend(original, status: "EN ELABORACIÓN", inListas: false)
                    }
                    return original
                }
                if ["rework", "prepare", "hints"].contains(action.decision) {
                    if !updated.trendsElaboracion.contains(where: {
                        $0.editorialID == action.id && $0.revision >= action.revision
                    }) {
                        updated.trendsElaboracion.insert(
                            TrendItem(id: "optimistic-" + action.key, rank: action.rank,
                                      name: action.title, explanation: "",
                                      lastExplained: nil, status: "EN ELABORACIÓN",
                                      inListas: false, editorialID: action.id,
                                      revision: action.revision + (action.decision == "hints" ? 1 : 0), imageURL: nil,
                                      sourceURL: nil), at: 0)
                    }
                }
            }
        }
        snapshot = applyConfirmedTerminals(updated)
    }

    private func refreshOptimisticActivity() {
        Task {
            await publishLiveCounts(checkedAt: Date(),
                                    partial: snapshot.partial || pendingOperationsCount > 0)
        }
    }

    // Snapshot baseline advances when leaving the app, not on every refresh.
    // This preserves the entire set of changes during a visit.
    func markVisitComplete() {
        guard let snapshot = currentVisitSnapshot else { return }
        UserDefaults.standard.set(snapshot, forKey: "TTActualidad.editorial.baseline.v1")
        reviewedNews.removeAll()
        reviewedTrends.removeAll()
        // Unread entries survive restarting the app. Only opening the
        // corresponding card, or removing it from the feed, clears them.
    }

    private func updateNovedades(news: [NewsItem], trends: [TrendItem], top30: [TrendItem],
                                 newsWorking: [NewsItem], trendsWorking: [TrendItem]) {
        let key = "TTActualidad.editorial.baseline.v1"
        let defaults = UserDefaults.standard
        var current: [String: String] = [:]
        for item in news { current["N:" + item.id] = String(item.revision) }
        for item in trends { current["T:" + item.editorialID] = String(item.revision) }
        for item in top30 { current["R:" + item.name] = String(item.rank) }
        for item in newsWorking { current["W:N:" + item.id] = String(item.revision) }
        for item in trendsWorking { current["W:T:" + item.editorialID] = String(item.revision) }
        currentVisitSnapshot = current
        if let before = defaults.dictionary(forKey: key) as? [String: String] {
            unreviewedNews.formUnion(news.filter {
                before["N:" + $0.id] != String($0.revision) && !reviewedNews.contains($0.id)
            }.map(\.id) + newsWorking.filter {
                before["W:N:" + $0.id] != String($0.revision) && !reviewedNews.contains($0.id)
            }.map(\.id))
            unreviewedTrends.formUnion((trends + trendsWorking).filter {
                before["T:" + $0.editorialID] != String($0.revision) &&
                !reviewedTrends.contains($0.name)
            }.map(\.name) + top30.filter {
                before["R:" + $0.name] == nil &&
                !reviewedTrends.contains($0.name)
            }.map(\.name))
            // A moved rank is not an unread editorial draft. Keep only
            // currently visible unread IDs and entries not explicitly opened.
            let presentNews = Set((news + newsWorking).map(\.id))
            let presentTrends = Set((trends + trendsWorking + top30).map(\.name))
            unreviewedNews.formIntersection(presentNews)
            unreviewedTrends.formIntersection(presentTrends)
            unreviewedNews.subtract(reviewedNews)
            unreviewedTrends.subtract(reviewedTrends)
            storeUnread()
            var changes: [String] = []
            for item in news {
                let old = before["N:" + item.id]
                if old == nil { changes.append("Noticia lista: " + item.title) }
                else if old != String(item.revision) {
                    changes.append("Noticia actualizada: " + item.title)
                }
            }
            for item in trends {
                let old = before["T:" + item.editorialID]
                if old == nil { changes.append("Tendencia lista: " + item.name) }
                else if old != String(item.revision) {
                    changes.append("Tendencia reelaborada: " + item.name)
                }
            }
            for item in newsWorking where before["W:N:" + item.id] == nil {
                changes.append("Nueva elaboración de noticia: " + item.title)
            }
            for item in trendsWorking where before["W:T:" + item.editorialID] == nil {
                changes.append("Nueva elaboración de tendencia: " + item.name)
            }
            for item in top30 {
                let original = before["R:" + item.name]
                if original == nil {
                    changes.append("Nueva tendencia #" + String(item.rank) + ": " + item.name)
                } else if let rank = Int(original!), rank != item.rank {
                    changes.append(item.name + ": #" + String(rank) + " → #" + String(item.rank))
                }
            }
            novedades = Array(changes.prefix(60))
        } else {
            novedades = ["Primera sincronización completa: seguimiento de novedades activado."]
        }
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
    // ISO8601DateFormatter construction is expensive and these parsers are
    // called for every item in multiple ledgers on each refresh. Reuse them
    // only on the store's MainActor (they are never shared across threads).
    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let standardISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func when(_ row: [String: Any], _ keys: [String]) -> Date? {
        for key in keys {
            let text = str(row, key)
            guard !text.isEmpty else { continue }
            if let date = fractionalISO.date(from: text) ?? standardISO.date(from: text) {
                return date
            }
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
            guard !id.isEmpty, !closed.contains(statuses[id] ?? ""),
                  item["rewrite_pending"] as? Bool != true else { return nil }
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

    private static func isListasCovered(_ row: [String: Any]) -> Bool {
        str(row, "listas_group_role") == "covered" && !str(row, "covered_by_id").isEmpty &&
            (row["covered_source_revision"] == nil || int(row, "covered_source_revision") == int(row, "revision"))
    }

    private static func buildTrendListas(
        manual: [String: Any], requests: [String: Any], deliveries: [String: Any],
        decisions: [String: Any], queue: [String: Any], now: Date,
        archivePhotos: [String: URL],
        siteImages: [String: SiteAIImageCatalog.Entry]
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
            let rev = int(row, "revision")
            let req = latestRequests[id] ?? [:]
            let delivery = latestDeliveries[id] ?? [:]
            let reqRev = int(req, "revision"), reqStatus = str(req, "status").lowercased()
            let readyAfterRequest = explained.timeIntervalSince(when(req, ["requested_at"]) ?? .distantPast) >= -60
            if !req.isEmpty && reqRev > rev { return nil }
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
                if oldRev != rev { return oldRev > rev }
                let closedAt = Self.when(event, ["deleted_at", "dismissed_at", "published_at",
                                                 "removed_at", "updated_at", "delivered_at", "decided_at"])
                return !(closedAt != nil && closedAt!.timeIntervalSince(explained) < -60)
            }
            if closures.contains(where: {
                [Self.str($0, "id"), Self.str($0, "event_id")].contains(id) && closureApplies($0)
            }) || closureApplies(delivery) { return nil }

            let archive = row["archive_image"] as? [String: Any] ??
                          row["fallback_image"] as? [String: Any] ?? [:]
            return TrendItem(id: id, rank: int(row, "rank"), name: str(row, "name"),
                             explanation: str(row, "explanation"), lastExplained: explained,
                             status: isListasCovered(row) ? "AGRUPADA" :
                                (str(row, "listas_group_role") == "joint" ? "CONJUNTA" : "EXPLICADA"), inListas: true,
                             editorialID: id, revision: rev,
                             imageURL: ArchivePhotoCatalog.resolved(
                                 project: "ttendencias", id: id, revision: rev,
                                 image: URL(string: str(archive, "url")),
                                 catalog: archivePhotos),
                             sourceURL: URL(string: str(row, "source_url")),
                             coveredByID: isListasCovered(row) ? str(row, "covered_by_id") : "",
                             coveredByName: isListasCovered(row) ? str(row, "covered_by_name") : "",
                             isJointGroup: str(row, "listas_group_role") == "joint",
                             lastReviewed: when(row, ["red_review_checked_at"]),
                             reviewOutcome: str(row, "red_review_outcome"),
                             reviewReason: str(row, "red_review_reason"),
                             siteImageEditorialID: id,
                             siteImageRevision: rev,
                             siteImageExplainedAt: str(row, "explained_at"),
                             siteImageURL: SiteAIImageCatalog.resolved(
                                 id: id, revision: rev,
                                 explanation: str(row, "explanation"),
                                 explainedAt: str(row, "explained_at"),
                                 catalog: siteImages))
        }
        .sorted {
            let leftRank = $0.rank > 0 ? $0.rank : Int.max
            let rightRank = $1.rank > 0 ? $1.rank : Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            if $0.isCovered != $1.isCovered { return !$0.isCovered }
            let leftDate = $0.lastExplained ?? .distantPast
            let rightDate = $1.lastExplained ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id < $1.id
        }
        .prefix(500)
        .map { $0 }
    }

    /// A terminal deletion is authoritative even when a previous rework
    /// started under another ID. Compare the timestamp: a *later* new request
    /// with the same name must remain eligible to run.
    @MainActor
    private struct ClosedTrends {
        var byID: [String: Date]
        var byName: [String: Date]

        func isClosed(id: String, name: String, since: Date) -> Bool {
            if let closed = byID[id], closed >= since.addingTimeInterval(-5) {
                return true
            }
            let normalized = EditorialStore.norm(name)
            return (byName[normalized] ?? .distantPast) >= since.addingTimeInterval(-5)
        }
    }

    private static func closedTrends(manual: [String: Any], requests: [String: Any],
                                     decisions: [String: Any]) -> ClosedTrends {
        var result = ClosedTrends(byID: [:], byName: [:])
        func remember(_ row: [String: Any]) {
            guard closed.contains(str(row, "status").lowercased()) else { return }
            let id = str(row, "id")
            let name = norm(str(row, "name"))
            let time = when(row, ["deleted_at", "dismissed_at", "updated_at"]) ?? .distantPast
            if !id.isEmpty { result.byID[id] = max(result.byID[id] ?? .distantPast, time) }
            if !name.isEmpty { result.byName[name] = max(result.byName[name] ?? .distantPast, time) }
        }
        for item in rows(manual, "items") { remember(item) }
        for item in rows(requests, "requests") { remember(item) }
        for item in rows(decisions, "items") { remember(item) }
        return result
    }

    private static func buildTrendsElaboracion(
        requests: [String: Any], queue: [String: Any],
        manual: [String: Any], decisions: [String: Any], ready: [TrendItem]
    ) -> [TrendItem] {
        let readyByID = Dictionary(uniqueKeysWithValues: ready.map { ($0.editorialID, $0.revision) })
        let closures = closedTrends(manual: manual, requests: requests, decisions: decisions)
        var finishedByName: [String: Date] = [:]
        for row in rows(manual, "items") {
            guard ["explained", "deleted", "dismissed", "published"].contains(
                str(row, "status").lowercased()) else { continue }
            // An explained group has ONE leader card, but ALL covered names
            // must stop showing as work in progress. This also safeguards
            // partial refreshes where requests.json falls back to iOS cache.
            let names = [str(row, "name")] + (row["trend_names"] as? [String] ?? [])
            let timestamp = when(row, ["deleted_at", "explained_at", "updated_at"]) ?? .distantPast
            for value in names {
                let name = norm(value)
                if !name.isEmpty {
                    finishedByName[name] = max(finishedByName[name] ?? .distantPast, timestamp)
                }
            }
        }
        var result: [String: [String: Any]] = [:]
        for item in rows(requests, "requests") + rows(queue, "items") {
            let id = str(item, "id")
            let status = str(item, "status").lowercased()
            let name = str(item, "name")
            let requestedAt = when(item, ["requested_at", "created_at", "updated_at"]) ?? .distantPast
            guard !id.isEmpty, ["preparing", "update"].contains(status),
                  int(item, "revision") > (readyByID[id] ?? -1),
                  !closures.isClosed(id: id, name: name, since: requestedAt),
                  (finishedByName[norm(name)] ?? .distantPast) < requestedAt else {
                continue
            }
            if isNewer(item, than: result[id]) { result[id] = item }
        }
        return result.values.map { row in
            TrendItem(id: "work-" + str(row, "id"), rank: int(row, "rank"),
                      name: str(row, "name").isEmpty ? str(row, "id") : str(row, "name"),
                      explanation: str(row, "explanation"), lastExplained: when(row, ["explained_at"]),
                      status: "EN ELABORACIÓN", inListas: false,
                      editorialID: str(row, "id"), revision: int(row, "revision"),
                      imageURL: nil, sourceURL: URL(string: str(row, "source_url")))
        }
        .sorted { ($0.lastExplained ?? .distantPast) > ($1.lastExplained ?? .distantPast) }
    }

    private static func buildTop30(
        recent: [String: Any], manual: [String: Any], explained: [String: Any],
        requests: [String: Any], ready: [TrendItem], archivePhotos: [String: URL],
        siteImages: [String: SiteAIImageCatalog.Entry]
    ) -> [TrendItem] {
        let names = recent["top30"] as? [String] ?? []
        let radar = rows(recent, "items")
        var byRank: [Int: String] = [:]
        var movementByRank: [Int: [String: Any]] = [:]
        for (index, row) in radar.enumerated() {
            let rank = int(row, "rank") == 0 ? index + 1 : int(row, "rank")
            if (1...30).contains(rank) && !str(row, "name").isEmpty {
                byRank[rank] = str(row, "name")
                movementByRank[rank] = row
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
            if str(row, "listas_group_role") != "joint" {
                names += row["trend_names"] as? [String] ?? []
                names += (row["trend_context"] as? [[String: Any]] ?? []).map { str($0, "name") }
            }
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
            } else if ["problematic", "inactive"].contains(str(row, "status").lowercased()) &&
                      !str(row, "problem_reason").isEmpty {
                statuses[key] = "SIN EXPLICACIÓN"
            }
        }
        return (1...30).compactMap { rank -> TrendItem? in
            guard let name = byRank[rank], !name.isEmpty else { return nil }
            let key = norm(name), explanation = explanations[key] ?? [:]
            let text = str(explanation, "explanation")
            let date = when(explanation, ["explained_at"])
            let status: String = statuses[key] ??
                (text.isEmpty ? "PENDIENTE" : "EXPLICADA")
            let request = requestByName[key] ?? [:]
            let knownID = str(request, "id").isEmpty ? str(explanation, "id") : str(request, "id")
            // Backend accepts a stable manual ID for a Top 30 entry without any
            // previous request. A blank ID would make "Preparar" impossible.
            let digest = SHA256.hash(data: Data(name.utf8))
            let manualID = "manual-" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
            let editorialID = knownID.isEmpty ? String(manualID) : knownID
            let revision = request.isEmpty ? int(explanation, "revision") : int(request, "revision")
            let archive = explanation["archive_image"] as? [String: Any] ??
                          explanation["fallback_image"] as? [String: Any] ?? [:]
            let source = str(request, "source_url")
            let trendMovement = movementByRank[rank] ?? [:]
            return TrendItem(id: "rank-\(rank)", rank: rank, name: name,
                             explanation: text, lastExplained: text.isEmpty ? nil : date,
                             status: status, inListas: readyNames.contains(key),
                             editorialID: editorialID, revision: revision,
                             imageURL: ArchivePhotoCatalog.resolved(
                                 project: "ttendencias", id: editorialID,
                                 revision: revision, image: URL(string: str(archive, "url")),
                                 catalog: archivePhotos),
                             sourceURL: URL(string: source),
                             rankDelta: int(trendMovement, "rank_delta"),
                             movement: str(trendMovement, "movement"),
                             enteredAt: when(trendMovement, ["entered_top10_at", "entered_at"]),
                             problemReason: str(request, "problem_reason"),
                             coveredByID: isListasCovered(request) ? str(request, "covered_by_id") : "",
                             coveredByName: isListasCovered(request) ? str(request, "covered_by_name") : "",
                             isJointGroup: str(request, "listas_group_role") == "joint",
                             lastReviewed: when(explanation, ["red_review_checked_at"]),
                             reviewOutcome: str(explanation, "red_review_outcome"),
                             reviewReason: str(explanation, "red_review_reason"),
                             siteImageEditorialID: str(explanation, "id"),
                             siteImageRevision: int(explanation, "revision"),
                             siteImageExplainedAt: str(explanation, "explained_at"),
                             siteImageURL: SiteAIImageCatalog.resolved(
                                 id: str(explanation, "id"),
                                 revision: int(explanation, "revision"),
                                 explanation: text,
                                 explainedAt: str(explanation, "explained_at"),
                                 catalog: siteImages))
        }
    }

    // Historical unresolved trends remain visible in Pendientes even after
    // dropping out of the current Top 30. Never resurrect terminal decisions.
    private static func buildUnexplainedTrends(
        requests: [String: Any], decisions: [String: Any], now: Date
    ) -> [TrendItem] {
        let closedIDs = Set(rows(decisions, "items").filter {
            closed.contains(str($0, "status").lowercased())
        }.map { str($0, "id") })
        var latest: [String: [String: Any]] = [:]
        for row in rows(requests, "requests") {
            let id = str(row, "id")
            if !id.isEmpty && isNewer(row, than: latest[id]) { latest[id] = row }
        }
        return latest.values.compactMap { row -> TrendItem? in
            let status = str(row, "status").lowercased()
            let id = str(row, "id")
            let name = str(row, "name")
            let reason = str(row, "problem_reason")
            let last = when(row, ["inactive_at", "last_attempt_at", "requested_at"])
            guard ["problematic", "inactive"].contains(status),
                  !closedIDs.contains(id), !name.isEmpty, !reason.isEmpty,
                  let last, now.timeIntervalSince(last) >= -60 * 60,
                  now.timeIntervalSince(last) < 7 * 24 * 3600 else { return nil }
            return TrendItem(id: "unexplained-" + id, rank: int(row, "rank"),
                             name: name, explanation: "", lastExplained: nil,
                             status: "SIN EXPLICACIÓN", inListas: false,
                             editorialID: id, revision: int(row, "revision"),
                             imageURL: nil, sourceURL: nil, problemReason: reason)
        }.sorted { $0.name < $1.name }
    }

    private func publishLiveCounts(checkedAt: Date, partial: Bool) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveStatus = "Activa las Live Activities en Ajustes del iPhone"
            return
        }
        let state = LiveCountsAttributes.ContentState(
            newsReady: snapshot.news.count,
            trendsReady: snapshot.trendListas.count,
            newsWorking: snapshot.newsElaboracion.count,
            trendsWorking: snapshot.trendsElaboracion.count,
            pendingActions: pendingOperationsCount,
            checkedAt: checkedAt, partialData: partial,
            recentHeadline: snapshot.news.max(by: {
                ($0.publishedAt ?? .distantPast) <
                ($1.publishedAt ?? .distantPast)
            })?.title ?? "",
            newsPublished24h: publicationsLast24h(project: "ttittulares",
                                                    now: checkedAt) ?? 0,
            trendsPublished24h: publicationsLast24h(project: "ttendencias",
                                                      now: checkedAt) ?? 0,
            publishedCountsAvailable: publicationLedgerAvailable
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


/// All GitHub bytes are downloaded, validated and cached outside MainActor.
/// The returned JSON dictionaries are immutable after crossing the actor
/// boundary; @unchecked Sendable is confined to this single read-only result.
private struct EditorialDocumentLoad: @unchecked Sendable {
    let downloaded: [String: Data]
    let docs: [String: [String: Any]]
    let partial: Bool
}

private enum EditorialDocumentLoader {
    static func load(paths: [String]) async -> EditorialDocumentLoad {
        var downloaded: [String: Data] = [:]
        let freshNonce = String(Int(Date().timeIntervalSince1970 * 1000))
        await withTaskGroup(of: (String, Data?).self) { group in
            for path in paths {
                group.addTask {
                    guard let url = URL(string:
                        "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/" +
                        path + "?check=" + freshNonce) else { return (path, nil) }
                    var request = URLRequest(
                        url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 16)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200,
                              (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
                        else { return (path, nil) }
                        return (path, data)
                    } catch { return (path, nil) }
                }
            }
            for await (path, data) in group {
                if let data { downloaded[path] = data }
            }
        }

        let root = FileManager.default.urls(for: .cachesDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("TTActualidadGitHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: root,
                                                  withIntermediateDirectories: true)
        var docs: [String: [String: Any]] = [:]
        var partial = false
        for path in paths {
            let cacheURL = root.appendingPathComponent(
                path.replacingOccurrences(of: "/", with: "_"))
            let source: Data?
            if let data = downloaded[path] {
                try? data.write(to: cacheURL, options: .atomic)
                source = data
            } else {
                partial = true
                source = try? Data(contentsOf: cacheURL)
            }
            if let source,
               let parsed = (try? JSONSerialization.jsonObject(with: source)) as? [String: Any] {
                docs[path] = parsed
            } else {
                partial = true
            }
        }
        return EditorialDocumentLoad(downloaded: downloaded, docs: docs,
                                     partial: partial)
    }
}

