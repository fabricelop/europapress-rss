import Combine
import SwiftUI

// Single shared read-only summary. EditorialActions is instantiated for many
// cards; querying Sites separately per card would waste requests and race.
@MainActor
final class EditorialRelationCountsStore: ObservableObject {
    static let shared = EditorialRelationCountsStore()
    @Published private(set) var revision = 0
    private(set) var snapshot: EditorialRelationsSnapshot?
    private(set) var news: [EditorialRelationEndpoint] = []
    private var loadedAt: Date?
    private var loading = false

    func refresh(using github: GitHubEditor, force: Bool = false) async {
        if loading { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 90 { return }
        guard github.authenticated else { return }
        loading = true
        defer { loading = false }
        // Do not claim 0/X when GET failed. A verified Site read is required.
        do {
            async let history = github.editorialRelationRecentNews()
            let (raw, status) = try await github.privateEditorialRelationsRequest(
                path: "/v1/snapshot")
            guard status == 200 else { return }
            let verified = try JSONDecoder().decode(
                EditorialRelationsSnapshot.self, from: raw)
            let recent = (try? await history) ?? []
            snapshot = verified
            var byIdentity: [String: EditorialRelationEndpoint] = [:]
            let related = EditorialRelationsPolicy.canonical(verified.items)
            for row in verified.news + related.map(\.news) + recent {
                let id = EditorialRelationsPolicy.newsKey(
                    id: row.id, revision: row.revision)
                if let current = byIdentity[id],
                   !current.episodeFingerprint.isEmpty &&
                    row.episodeFingerprint.isEmpty {
                    continue
                }
                byIdentity[id] = row
            }
            news = Array(byIdentity.values)
            loadedAt = Date()
            revision &+= 1
        } catch {
            // Keep previous verified snapshot, never convert an error to zero.
        }
    }

    // X = server-confirmed links among the same N <= 5 textual suggestions.
    // No links are inferred merely because the headline mentions the trend.
    func counts(trendID: String, revision: Int, name: String) -> (Int, Int)? {
        guard let snapshot, !trendID.isEmpty else { return nil }
        let found = EditorialRelationsPolicy.newsForTrend(news, name: name)
        let links = EditorialRelationsPolicy.canonical(snapshot.items)
        let associated = found.filter { news in
            links.contains { pair in
                pair.state == "linked" &&
                    pair.news.id == news.id && pair.news.revision == news.revision &&
                    pair.trend.id == trendID && pair.trend.revision == revision
            }
        }.count
        return (associated, found.count)
    }
}

struct EditorialRelationsScope {
    let project: String
    let id: String
    let revision: Int
    let title: String
}

@MainActor
private final class EditorialRelationsModel: ObservableObject {
    @Published private(set) var snapshot: EditorialRelationsSnapshot?
    @Published private(set) var historicalNews: [EditorialRelationEndpoint] = []
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    // Rebuild the expensive trend/news matching cache once per completed
    // download, never for each checkbox tap or SwiftUI List body update.
    @Published private(set) var dataRevision = 0
    @Published var notice = ""
    // Persist retry identities across reopening the APP, so an uncertain
    // response cannot accidentally create a second command.
    private let commandStorageKey = "TTActualidad.editorial-relation-commandIds.v1"
    private var commands: [String: String] =
        UserDefaults.standard.dictionary(forKey: "TTActualidad.editorial-relation-commandIds.v1")
        as? [String: String] ?? [:]

    func load(using github: GitHubEditor) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // Fetch the private identities and the retained GitHub news history
        // independently: a missing/partial Sites snapshot must NOT make the
        // dated news inbox empty. Real links still require private receipts.
        async let datedHistory = github.editorialRelationRecentNews()
        var issues: [String] = []
        do {
            let (data, status) = try await github.privateEditorialRelationsRequest(path: "/v1/snapshot")
            guard status == 200 else { throw RelationsError.http(status) }
            snapshot = try JSONDecoder().decode(EditorialRelationsSnapshot.self, from: data)
        } catch {
            snapshot = nil
            issues.append("No se pudieron cargar las identidades de relaciones: \(error.localizedDescription)")
        }
        do {
            historicalNews = try await datedHistory
            if historicalNews.isEmpty {
                issues.append("El catálogo histórico no devolvió noticias; no se puede concluir que no existan coincidencias.")
            }
        } catch {
            historicalNews = []
            issues.append("No se pudieron recuperar las noticias históricas: \(error.localizedDescription)")
        }
        notice = issues.joined(separator: ". ")
        dataRevision &+= 1
    }

    private func commandKey(news: EditorialRelationEndpoint,
                            trend: EditorialRelationEndpoint, action: String) -> String {
        // A Sites refresh may add fingerprints without changing the pair.
        // Keep retries idempotent across that identity enrichment.
        [action, news.id, String(news.revision), trend.id,
         String(trend.revision)].joined(separator: "|")
    }

    private func retireVerifiedCommand(news: EditorialRelationEndpoint,
                                       trend: EditorialRelationEndpoint, action: String) {
        commands.removeValue(forKey: commandKey(news: news, trend: trend, action: action))
        UserDefaults.standard.set(commands, forKey: commandStorageKey)
    }

    private func postDecision(news: EditorialRelationEndpoint,
                              trend: EditorialRelationEndpoint,
                              action: String, using github: GitHubEditor) async throws {
        let key = commandKey(news: news, trend: trend, action: action)
        let command = commands[key] ?? UUID().uuidString.lowercased()
        commands[key] = command
        UserDefaults.standard.set(commands, forKey: commandStorageKey)
        let body = try JSONEncoder().encode(EditorialRelationDecision(
            action: action, expectedNews: news.identity, expectedTrend: trend.identity,
            commandId: command))
        let (data, status) = try await github.privateEditorialRelationsRequest(
            path: "/v1/decisions", method: "POST", jsonBody: body)
        if status == 409 {
            commands.removeValue(forKey: key)
            UserDefaults.standard.set(commands, forKey: commandStorageKey)
            throw RelationsError.http(status)
        }
        guard status == 200 else { throw RelationsError.http(status) }
        let receipt = try JSONDecoder().decode(EditorialRelationReceipt.self, from: data)
        guard EditorialRelationsPolicy.confirms(receipt, action: action) else {
            throw RelationsError.unconfirmed
        }
        // Keep the same commandId until a fresh Site snapshot exposes the
        // relation. A stale GET must not create a new command on retry.
    }

    func decide(news: EditorialRelationEndpoint, trend: EditorialRelationEndpoint,
                action: String, using github: GitHubEditor) async {
        guard !saving, ["link", "unlink", "dismiss"].contains(action) else { return }
        saving = true
        defer { saving = false }
        do {
            try await postDecision(news: news, trend: trend, action: action, using: github)
            await load(using: github)
            let persisted = EditorialRelationsPolicy.persisted(
                snapshot?.items ?? [], news: news, trend: trend, action: action)
            if persisted {
                retireVerifiedCommand(news: news, trend: trend, action: action)
            }
            notice = persisted ?
                (action == "link" ? "Relación guardada y comprobada en el Site." :
                 "Relación bloqueada y comprobada en el Site.") :
                "La orden fue aceptada, pero la relación aún no aparece en el Site. " +
                "No se dará por guardada hasta confirmarla en la web."
        } catch {
            if let failure = error as? RelationsError, case .http(409) = failure {
                await load(using: github)
            }
            notice = "No se ha confirmado la decisión: \(error.localizedDescription)"
        }
    }

    struct TrendSaveResult {
        let confirmedKeys: [String]
        let attempted: Int
        let errors: [String]
    }

    // One deliberate Save per expanded trend. Requests are still individually
    // authenticated by Sites, but checkbox changes never POST and the costly
    // source refresh happens only ONCE after the whole selected batch.
    func saveTrendChanges(
        _ changes: [(news: EditorialRelationEndpoint,
                     trend: EditorialRelationEndpoint, action: String)],
        using github: GitHubEditor
    ) async -> TrendSaveResult {
        guard !saving, !changes.isEmpty else {
            return TrendSaveResult(confirmedKeys: [], attempted: 0, errors: [])
        }
        saving = true
        defer { saving = false }
        var confirmed: [String] = []
        var errors: [String] = []
        var seen = Set<String>()
        for (index, change) in changes.enumerated() {
            let pair = EditorialRelationsPolicy.pairKey(change.news, change.trend)
            guard seen.insert(pair).inserted else { continue }
            notice = "Solicitando guardado de relaciones: " +
                String(index + 1) + "/" + String(changes.count)
            do {
                try await postDecision(news: change.news, trend: change.trend,
                                       action: change.action, using: github)
                confirmed.append(pair)
            } catch {
                errors.append(change.news.title + ": " + error.localizedDescription)
                // A conflict requires a fresh episode identity. Do not keep
                // writing with a stale fingerprint.
                if let conflict = error as? RelationsError,
                   case .http(409) = conflict { break }
            }
        }
        await load(using: github)
        let visible = confirmed.filter { pair in
            changes.contains { change in
                EditorialRelationsPolicy.pairKey(change.news, change.trend) == pair &&
                    EditorialRelationsPolicy.persisted(
                        snapshot?.items ?? [], news: change.news,
                        trend: change.trend, action: change.action)
            }
        }
        for change in changes where visible.contains(
            EditorialRelationsPolicy.pairKey(change.news, change.trend)) {
            retireVerifiedCommand(news: change.news, trend: change.trend,
                                  action: change.action)
        }
        if visible.count < confirmed.count {
            errors.append("El Site aún no devuelve " +
                String(confirmed.count - visible.count) +
                " relación(es) aceptadas. Conserva las selecciones hasta comprobarlas.")
        }
        let summary = String(visible.count) + " de " + String(changes.count) +
            " cambios visibles y confirmados en el Site."
        notice = errors.isEmpty ? summary :
            summary + " Pendientes o rechazados: " +
            errors.prefix(2).joined(separator: " · ") +
            (errors.count > 2 ? " (y más)" : "")
        return TrendSaveResult(confirmedKeys: visible,
                               attempted: changes.count, errors: errors)
    }

    // Save only pairs explicitly changed by the editor. No automatic mass
    // dismissal of unchecked suggestions; no modification of unrelated trends.
    func saveSelection(news: EditorialRelationEndpoint,
                       links: [EditorialRelationEndpoint],
                       unlinks: [EditorialRelationEndpoint],
                       using github: GitHubEditor) async -> Bool {
        guard !saving, !links.isEmpty || !unlinks.isEmpty else { return false }
        saving = true
        defer { saving = false }
        let operations: [(trend: EditorialRelationEndpoint, action: String)] =
            links.map { (trend: $0, action: "link") } +
            unlinks.map { (trend: $0, action: "unlink") }
        var linked = 0
        var unlinked = 0
        var errorMessage: String?
        var seen = Set<String>()
        for operation in operations {
            let trend = operation.trend
            let key = trend.stableIdentity
            guard seen.insert(key).inserted else { continue }
            do {
                try await postDecision(news: news, trend: trend,
                                       action: operation.action, using: github)
                if operation.action == "link" { linked += 1 } else { unlinked += 1 }
            } catch {
                errorMessage = error.localizedDescription
                // Stop on a stale editorial identity; continuing with it can
                // create misleading receipts on unrelated episodes.
                if let failure = error as? RelationsError,
                   case .http(409) = failure { break }
            }
        }
        await load(using: github)
        let checkedLinks = links.filter {
            EditorialRelationsPolicy.persisted(
                snapshot?.items ?? [], news: news, trend: $0, action: "link")
        }.count
        let checkedUnlinks = unlinks.filter {
            EditorialRelationsPolicy.persisted(
                snapshot?.items ?? [], news: news, trend: $0, action: "unlink")
        }.count
        for trend in links where EditorialRelationsPolicy.persisted(
            snapshot?.items ?? [], news: news, trend: trend, action: "link") {
            retireVerifiedCommand(news: news, trend: trend, action: "link")
        }
        for trend in unlinks where EditorialRelationsPolicy.persisted(
            snapshot?.items ?? [], news: news, trend: trend, action: "unlink") {
            retireVerifiedCommand(news: news, trend: trend, action: "unlink")
        }
        if checkedLinks != linked || checkedUnlinks != unlinked {
            errorMessage = "El Site todavía no muestra todas las relaciones aceptadas."
        }
        let completed = "\(checkedLinks) asociadas · \(checkedUnlinks) desasociadas"
        if let errorMessage {
            notice = completed + ". Hay cambios sin confirmar: " +
                errorMessage + ". Revisa las marcas antes de reintentar."
        } else {
            notice = completed + " para «\(news.title)», comprobadas en el Site."
        }
        return errorMessage == nil
    }

    private enum RelationsError: LocalizedError {
        case http(Int), unconfirmed
        var errorDescription: String? {
            switch self {
            case .http(401), .http(403): return "Conecta tu cuenta GitHub de editor."
            case .http(409): return "Una ficha ha cambiado. Se han actualizado las relaciones; revisa antes de reintentar."
            case .http(let status): return "El servidor devolvió \(status)."
            case .unconfirmed: return "La confirmación del servidor no es válida."
            }
        }
    }
}

struct EditorialRelationsView: View {
    @ObservedObject var github: GitHubEditor
    var scope: EditorialRelationsScope? = nil
    var top30Names: [String] = []
    var top30Trends: [TrendItem] = []
    var listasNews: [NewsItem] = []
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = EditorialRelationsModel()
    @State private var filter = "suggested"
    // Switches are local drafts until exact server receipts arrive.
    @State private var pendingSwitches: [String: Bool] = [:]
    // A visible Top30 row remains tappable even before Sites provides an
    // endpoint fingerprint. Store intent locally; NEVER fabricate a receipt.
    @State private var unresolvedTop30Selections = Set<String>()
    @State private var expandedTop30 = Set<String>()
    // The primary inbox is now trend-first, not a selectable 12/24-hour news window.
    @State private var expandedTrends = Set<String>()
    // Each expensive source join/search runs only after a real data refresh.
    // SwiftUI checkbox taps and DisclosureGroup animations then stay O(1).
    @State private var indexedNews: [EditorialRelationEndpoint] = []
    @State private var indexedCanonical: [EditorialRelation] = []
    @State private var indexedMatches: [String: [EditorialRelationEndpoint]] = [:]
    @State private var indexedTrendEndpoints: [String: EditorialRelationEndpoint] = [:]
    @State private var indexedRelationStates: [String: String] = [:]
    @State private var indexedDates: [String: Date] = [:]
    @State private var showHiddenNews = false
    private let hiddenStorageKey = "TTActualidad.relations-hidden-news.v1"
    @State private var hiddenNews = Set(
        UserDefaults.standard.stringArray(forKey: "TTActualidad.relations-hidden-news.v1") ?? [])
    @State private var showManualLinking = false
    @State private var selectedNews: EditorialRelationEndpoint?
    @State private var picker: EndpointPickerRoute?

    private struct EndpointPickerRoute: Identifiable {
        let project: String
        var id: String { project }
    }

    private var scopedEndpoint: EditorialRelationEndpoint? {
        guard let scope, let snapshot = model.snapshot else { return nil }
        return (scope.project == "ttittulares" ? snapshot.news : snapshot.trends).first {
            EditorialRelationsPolicy.matches($0, id: scope.id, revision: scope.revision)
        }
    }

    private var canonicalRelations: [EditorialRelation] { indexedCanonical }

    private var activeListasKeys: Set<String> {
        Set(listasNews.map { EditorialRelationsPolicy.newsKey(id: $0.id, revision: $0.revision) })
    }

    private var relations: [EditorialRelation] {
        canonicalRelations.filter { item in
            guard item.state == filter else { return false }
            if let scope {
                let endpoint = scope.project == "ttittulares" ? item.news : item.trend
                return EditorialRelationsPolicy.matches(endpoint, id: scope.id, revision: scope.revision)
            }
            // Historical or removed news never reappears automatically.
            return EditorialRelationsPolicy.isVisibleNews(
                item.news, activeListas: activeListasKeys, explicit: selectedNews)
        }
    }

    private var allNewsChoices: [EditorialRelationEndpoint] { indexedNews }

    private func buildAllNewsChoices(canonical: [EditorialRelation]) -> [EditorialRelationEndpoint] {
        // The server returns linkable episodes; GitHub returns extra recent
        // display-only episodes (fingerprint empty). Combine by exact ID and
        // revision, preferring any server-issued fingerprint for decisions.
        let candidates = (model.snapshot?.news ?? []) +
            canonical.map(\.news) + model.historicalNews
        var byKey: [String: EditorialRelationEndpoint] = [:]
        for row in candidates {
            let key = EditorialRelationsPolicy.newsKey(id: row.id, revision: row.revision)
            if let old = byKey[key] {
                let preferred = old.episodeFingerprint.isEmpty &&
                    !row.episodeFingerprint.isEmpty ? row : old
                let oldDate = EditorialRelationsPolicy.parsedDate(old.listedAt)
                let newDate = EditorialRelationsPolicy.parsedDate(row.listedAt)
                let date: String?
                if let oldDate, let newDate {
                    date = oldDate >= newDate ? old.listedAt : row.listedAt
                } else {
                    date = row.listedAt ?? old.listedAt
                }
                byKey[key] = EditorialRelationEndpoint(
                    id: preferred.id, revision: preferred.revision,
                    episodeFingerprint: preferred.episodeFingerprint,
                    title: preferred.title.count >= row.title.count ? preferred.title : row.title,
                    text: preferred.text.count >= row.text.count ? preferred.text : row.text,
                    path: preferred.path, listedAt: date)
            } else {
                byKey[key] = row
            }
        }
        return byKey.values.sorted { a, b in
            if (a.listedAt ?? "") != (b.listedAt ?? "") {
                return (a.listedAt ?? "") > (b.listedAt ?? "")
            }
            if a.revision != b.revision { return a.revision > b.revision }
            return a.title < b.title
        }
    }

    private var fallbackDates: [String: Date] { indexedDates }

    private func buildFallbackDates() -> [String: Date] {
        var dates: [String: Date] = [:]
        for item in model.historicalNews {
            let key = EditorialRelationsPolicy.newsKey(id: item.id, revision: item.revision)
            if let date = EditorialRelationsPolicy.parsedDate(item.listedAt) {
                dates[key] = date
            }
        }
        for item in listasNews {
            let key = EditorialRelationsPolicy.newsKey(id: item.id, revision: item.revision)
            if dates[key] == nil,
               let date = EditorialRelationsPolicy.parsedDate(item.preparedAtISO) ?? item.publishedAt {
                dates[key] = date
            }
        }
        return dates
    }

    private func trendKey(rank: Int, name: String) -> String {
        String(rank) + ":" + name
    }

    private func relatedNews(rank: Int, name: String) -> [EditorialRelationEndpoint] {
        indexedMatches[trendKey(rank: rank, name: name)] ?? []
    }

    private func rebuildRelationIndex() {
        let canonical = EditorialRelationsPolicy.canonical(model.snapshot?.items ?? [])
        let news = buildAllNewsChoices(canonical: canonical)
        let dates = buildFallbackDates()
        let endpoints = (model.snapshot?.trends ?? []) + canonical.map(\.trend)
        var states: [String: String] = [:]
        for relation in canonical {
            let key = pairKey(relation.news, relation.trend)
            states[key] = relation.state
        }
        var matches: [String: [EditorialRelationEndpoint]] = [:]
        var trends: [String: EditorialRelationEndpoint] = [:]
        let now = Date()
        for (index, name) in top30Names.prefix(30).enumerated() {
            let rank = index + 1
            let key = trendKey(rank: rank, name: name)
            matches[key] = EditorialRelationsPolicy.newsForTrend(
                news, name: name, now: now,
                fallbackDates: dates, limit: 5)
            if top30Trends.indices.contains(index) {
                let row = top30Trends[index]
                if row.name == name && !row.editorialID.isEmpty {
                    // Prefer an exact server episode; otherwise the current
                    // Top30 ID and revision remain valid selection references.
                    trends[key] = EditorialRelationsPolicy.matchingTop30Endpoint(
                        id: row.editorialID, revision: row.revision,
                        renderedText: row.explanation, candidates: endpoints) ??
                        EditorialRelationEndpoint(
                            id: row.editorialID, revision: row.revision,
                            episodeFingerprint: "", title: row.name,
                            text: row.explanation, path: nil)
                }
            }
        }
        // The per-card button must work for the exact trend opened, including
        // Listas, Recientes, Pendientes or Antiguas and changed Top 30 ranks.
        // It is never gated by Top 30 membership or a historical time window.
        if let scope, scope.project == "ttendencias" {
            let key = trendKey(rank: 0, name: scope.title)
            matches[key] = EditorialRelationsPolicy.newsForTrend(
                news, name: scope.title, now: now,
                fallbackDates: dates, limit: 5)
            let renderedText = top30Trends.first {
                $0.editorialID == scope.id && $0.revision == scope.revision
            }?.explanation ?? ""
            trends[key] = EditorialRelationsPolicy.matchingTop30Endpoint(
                id: scope.id, revision: scope.revision,
                renderedText: renderedText, candidates: endpoints) ??
                EditorialRelationEndpoint(
                    id: scope.id, revision: scope.revision,
                    episodeFingerprint: "", title: scope.title,
                    text: renderedText, path: nil)
        }
        indexedCanonical = canonical
        indexedNews = news
        indexedDates = dates
        indexedRelationStates = states
        indexedTrendEndpoints = trends
        indexedMatches = matches
    }

    private var hiddenNewsChoices: [EditorialRelationEndpoint] {
        allNewsChoices.filter {
            hiddenNews.contains($0.stableIdentity) ||
            hiddenNews.contains(EditorialRelationsPolicy.newsKey(id: $0.id, revision: $0.revision))
        }
    }

    private func hide(_ news: EditorialRelationEndpoint) {
        hiddenNews.insert(EditorialRelationsPolicy.newsKey(id: news.id, revision: news.revision))
        UserDefaults.standard.set(Array(hiddenNews).sorted(), forKey: hiddenStorageKey)
        expandedTop30.remove(news.stableIdentity)
        rebuildRelationIndex()
    }

    private func restore(_ news: EditorialRelationEndpoint) {
        hiddenNews.remove(news.stableIdentity)
        hiddenNews.remove(EditorialRelationsPolicy.newsKey(id: news.id, revision: news.revision))
        UserDefaults.standard.set(Array(hiddenNews).sorted(), forKey: hiddenStorageKey)
        rebuildRelationIndex()
    }

    @ViewBuilder private var selectedScopeSection: some View {
        if let scope {
            Section("Ficha seleccionada") {
                Text(scopedEndpoint?.title ?? scope.title).font(.headline)
                if model.snapshot != nil && scopedEndpoint == nil &&
                   scope.project != "ttendencias" {
                    Text("Esta ficha no está disponible con esa revisión. Actualiza la APP para consultar su estado actual.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var editorialNoticeSection: some View {
        if !model.notice.isEmpty {
            Section { Text(model.notice).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
        }
    }

    private var relationFilterSection: some View {
        Section {
            Picker("Estado de relaciones", selection: $filter) {
                Text("Por revisar").tag("suggested")
                Text("Confirmadas").tag("linked")
                Text("Bloqueadas").tag("blocked")
            }.pickerStyle(.segmented)
        }
    }

    private var top30RelationSection: some View {
        Section("Tendencias del Top 30 · \(min(30, top30Names.count))") {
            Text("Abre una tendencia para ver hasta 5 noticias que la mencionan en titular o texto, sin filtros de fecha, Listas ni estado. Solo tu decisión confirmada crea una relación.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Noticias del historial recuperadas: \(model.historicalNews.count)")
                .font(.caption).foregroundStyle(.secondary)
            if top30Names.isEmpty && !model.loading {
                Text("No está disponible el Top 30 actual. Actualiza la APP.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(top30Names.prefix(30).enumerated()), id: \.offset) { index, name in
                trendCard(rank: index + 1, name: name)
            }
        }
    }

    private var existingRelationsSection: some View {
        Section(filter == "linked" ? "Relaciones confirmadas por noticia" :
                filter == "blocked" ? "Relaciones bloqueadas por noticia" :
                "Relaciones de la ficha seleccionada") {
            if newsGroups.isEmpty && !model.loading {
                Text("No hay noticias con relaciones en este estado.")
                    .foregroundStyle(.secondary)
            }
            ForEach(newsGroups, id: \.stableIdentity) { news in
                newsCard(news)
            }
        }
    }

    @ViewBuilder private var manualNewsSelectionSection: some View {
        if filter == "suggested", scope == nil, let selectedNews {
            Section("Edición manual · noticia elegida") { newsCard(selectedNews) }
        }
    }

    @ViewBuilder private var hiddenRelationNewsSection: some View {
        if filter == "suggested" && scope == nil && !hiddenNewsChoices.isEmpty {
            Section {
                DisclosureGroup("Ocultas (\(hiddenNewsChoices.count))", isExpanded: $showHiddenNews) {
                    ForEach(hiddenNewsChoices, id: \.stableIdentity) { news in
                        HStack {
                            Text(news.title).font(.subheadline)
                            Spacer()
                            Button("Restaurar") { restore(news) }
                                .font(.caption)
                        }
                    }
                    Text("Ocultar solo afecta a esta bandeja en este iPhone: no borra noticias ni modifica relaciones.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var manualSearchSection: some View {
        if filter == "suggested" {
            Section {
                DisclosureGroup("Elegir otra noticia", isExpanded: $showManualLinking) {
                    Text("Elige una noticia histórica de Listas para recuperar o añadir sus relaciones sin devolverla a Listas. Las fechas más recientes se muestran primero cuando el servidor las facilita.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        picker = EndpointPickerRoute(project: "ttittulares")
                    } label: {
                        Label(selectedNews?.title ?? "Buscar noticia",
                              systemImage: "newspaper")
                    }
                }
            }
        }
    }

    // The relationship button belongs to a concrete editorial trend, not
    // a global "Por revisar" menu. Show all known news matching this term,
    // regardless of when or where the news appeared. Only the editor links.
    @ViewBuilder private var scopedTrendNewsSection: some View {
        if let scope, scope.project == "ttendencias" {
            let rank = 0
            let name = scope.title
            let found = relatedNews(rank: rank, name: name)
            let changes = changesForTrend(found, rank: rank, name: name)
            Section("Noticias encontradas · " + String(found.count) + "/5") {
                Text("Búsqueda de «" + name +
                     "» en titulares y textos de noticias, sin filtros de fecha, " +
                     "Listas, estado ni publicación. Marca las que quieras " +
                     "relacionar y pulsa Guardar.")
                    .font(.footnote).foregroundStyle(.secondary)
                if found.isEmpty {
                    Text(model.loading ? "Buscando noticias…" :
                         allNewsChoices.isEmpty ?
                         "No se ha recuperado ningún catálogo de noticias. " +
                         "Actualiza y comprueba el aviso de carga." :
                         "No se encontraron noticias que mencionen esta tendencia.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(found, id: \.stableIdentity) { news in
                        trendNewsRow(news: news, rank: rank, name: name)
                    }
                }
                if !changes.isEmpty {
                    Button {
                        Task {
                            let result = await model.saveTrendChanges(changes, using: github)
                            for key in result.confirmedKeys { pendingSwitches.removeValue(forKey: key) }
                        }
                    } label: {
                        Label("Guardar " + String(changes.count) +
                              (changes.count == 1 ? " relación" : " relaciones"),
                              systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.saving)
                }
            }
        }
    }

    private var relationList: some View {
        List {
            selectedScopeSection
            editorialNoticeSection
            if scope?.project == "ttendencias" {
                scopedTrendNewsSection
            } else {
                relationFilterSection
                if filter == "suggested" && scope == nil {
                    top30RelationSection
                } else {
                    existingRelationsSection
                }
                manualNewsSelectionSection
                hiddenRelationNewsSection
                manualSearchSection
            }
        }
        .refreshable { await model.load(using: github) }
        .overlay {
            if model.loading && model.snapshot == nil {
                ProgressView("Consultando relaciones…")
            }
        }
        .disabled(model.saving)
    }

    private var currentTop30Identity: [String] {
        top30Trends.map { $0.editorialID + ":r" + String($0.revision) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if github.authenticated {
                    relationList
                } else {
                    ContentUnavailableView("Conecta GitHub", systemImage: "lock.shield",
                        description: Text("Las relaciones se gestionan solo con tu cuenta de editor."))
                }
            }
            .navigationTitle(scope == nil ? "Relaciones por noticia" : "Relaciones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.load(using: github) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.loading || model.saving || !github.authenticated)
                    .accessibilityLabel("Actualizar relaciones")
                }
            }
            .task {
                if github.authenticated {
                    await model.load(using: github)
                }
            }
            .onChange(of: model.dataRevision) { _, _ in rebuildRelationIndex() }
            .onChange(of: top30Names) { _, _ in rebuildRelationIndex() }
            .onChange(of: currentTop30Identity) { _, _ in rebuildRelationIndex() }
            .sheet(item: $picker) { route in
                EditorialEndpointPicker(
                    title: route.project == "ttittulares" ? "Seleccionar noticia" : "Seleccionar tendencia",
                    endpoints: route.project == "ttittulares" ?
                        allNewsChoices : model.snapshot?.trends ?? []) { endpoint in
                        selectedNews = endpoint
                        picker = nil
                    }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func same(_ left: EditorialRelationEndpoint,
                      _ right: EditorialRelationEndpoint) -> Bool {
        left.id == right.id && left.revision == right.revision
    }

    // One card per actual news episode, regardless of how many trend proposals
    // or server refreshes refer to it.
    private var newsGroups: [EditorialRelationEndpoint] {
        if filter == "suggested" && scope == nil {
            var result: [EditorialRelationEndpoint] = []
            if let explicit = selectedNews,
               !hiddenNews.contains(explicit.stableIdentity),
               !hiddenNews.contains(EditorialRelationsPolicy.newsKey(
                   id: explicit.id, revision: explicit.revision)),
               !result.contains(where: { $0.stableIdentity == explicit.stableIdentity }) {
                result.insert(explicit, at: 0)
            }
            return result
        }
        var seen = Set<String>()
        var group = relations.compactMap { item -> EditorialRelationEndpoint? in
            let news = item.news
            let key = EditorialRelationsPolicy.newsKey(id: news.id, revision: news.revision)
            return seen.insert(key).inserted ? news : nil
        }
        let explicit = selectedNews ?? (scope?.project == "ttittulares" ? scopedEndpoint : nil)
        if let explicit,
           seen.insert(EditorialRelationsPolicy.newsKey(
               id: explicit.id, revision: explicit.revision)).inserted {
            group.insert(explicit, at: 0)
        }
        return group
    }

    private func trendExpansion(rank: Int, name: String) -> Binding<Bool> {
        let key = trendKey(rank: rank, name: name)
        return Binding(get: { expandedTrends.contains(key) },
                       set: { value in
                           if value { expandedTrends.insert(key) }
                           else { expandedTrends.remove(key) }
                       })
    }

    private func currentTrendEndpoint(rank: Int, name: String) -> EditorialRelationEndpoint? {
        indexedTrendEndpoints[trendKey(rank: rank, name: name)]
    }

    private func confirmedCount(_ related: [EditorialRelationEndpoint],
                                rank: Int, name: String) -> Int {
        guard let trend = currentTrendEndpoint(rank: rank, name: name) else { return 0 }
        return related.filter { relationState($0, trend) == "linked" }.count
    }

    private func changesForTrend(_ related: [EditorialRelationEndpoint],
                                 rank: Int, name: String)
        -> [(news: EditorialRelationEndpoint,
             trend: EditorialRelationEndpoint, action: String)] {
        guard let trend = currentTrendEndpoint(rank: rank, name: name) else { return [] }
        return related.compactMap { news in
            guard let desired = pendingSwitches[pairKey(news, trend)],
                  let action = EditorialRelationsPolicy.actionForSwitch(
                      current: relationState(news, trend), selected: desired)
            else { return nil }
            return (news: news, trend: trend, action: action)
        }
    }

    private func trendCard(rank: Int, name: String) -> some View {
        let related = relatedNews(rank: rank, name: name)
        let associated = confirmedCount(related, rank: rank, name: name)
        let changes = changesForTrend(related, rank: rank, name: name)
        return DisclosureGroup(isExpanded: trendExpansion(rank: rank, name: name)) {
            if related.isEmpty {
                Text(model.historicalNews.isEmpty ?
                     "No se ha podido comprobar esta tendencia: el historial está vacío. Actualiza y revisa el aviso de carga." :
                     "No se encontraron coincidencias entre las noticias del historial recuperado.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(related, id: \.stableIdentity) { news in
                    trendNewsRow(news: news, rank: rank, name: name)
                }
                if !changes.isEmpty {
                    Button {
                        Task {
                            let result = await model.saveTrendChanges(
                                changes, using: github)
                            for key in result.confirmedKeys {
                                pendingSwitches.removeValue(forKey: key)
                            }
                        }
                    } label: {
                        Label("Guardar " + String(changes.count) +
                              (changes.count == 1 ? " cambio" : " cambios"),
                              systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.saving)
                }
            }
        } label: {
            HStack {
                Text(String(rank) + ".")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
                Text(name).font(.headline)
                Spacer()
                // Confirmed / found. Never claim a staged selection is saved.
                Text(String(associated) + "/" + String(related.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func trendNewsRow(news: EditorialRelationEndpoint,
                              rank: Int, name: String) -> some View {
        let trend = currentTrendEndpoint(rank: rank, name: name)
        let selectable = trend != nil
        let linkKey = trend.map { pairKey(news, $0) } ?? ""
        let linked = trend.map { relationState(news, $0) == "linked" } ?? false
        let selected = selectable ? (pendingSwitches[linkKey] ?? linked) : false
        return VStack(alignment: .leading, spacing: 8) {
            Text(news.title).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let date = EditorialRelationsPolicy.parsedDate(news.listedAt) ??
                fallbackDates[EditorialRelationsPolicy.newsKey(id: news.id, revision: news.revision)] {
                Text(date, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !news.text.isEmpty && news.text != news.title {
                Text(news.text).font(.caption)
                    .foregroundStyle(.secondary).lineLimit(3)
            }
            if let trend, selectable {
                Button {
                    toggleSelection(news, trend)
                } label: {
                    Label(selected ? "Asociada / seleccionada" : "Marcar para asociar",
                          systemImage: selected ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.plain).foregroundStyle(TTTheme.teal)
            } else {
                Text("No se reconoce el identificador de la tendencia.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if pendingSwitches[linkKey] != nil && selectable {
                Text(selected ? "Se asociará al pulsar Guardar" :
                     "Se desasociará al pulsar Guardar")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !selectable {
                Text("Identificador de tendencia pendiente.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if scope?.project != "ttendencias" {
                Button("Ocultar esta noticia") { hide(news) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
        }.padding(.vertical, 4)
    }

    private func rows(for news: EditorialRelationEndpoint) -> [EditorialRelation] {
        var seen = Set<String>()
        return relations.filter {
            same($0.news, news) && seen.insert($0.trend.stableIdentity).inserted
        }
    }

    private func pairKey(_ news: EditorialRelationEndpoint,
                         _ trend: EditorialRelationEndpoint) -> String {
        EditorialRelationsPolicy.pairKey(news, trend)
    }

    private func toggleSelection(_ news: EditorialRelationEndpoint,
                                 _ trend: EditorialRelationEndpoint) {
        let key = pairKey(news, trend)
        let isLinked = relationState(news, trend) == "linked"
        let next = !(pendingSwitches[key] ?? isLinked)
        if next == isLinked { pendingSwitches.removeValue(forKey: key) }
        else { pendingSwitches[key] = next }
    }

    private func expansion(_ news: EditorialRelationEndpoint) -> Binding<Bool> {
        let key = news.stableIdentity
        return Binding(
            get: { expandedTop30.contains(key) },
            set: { expanded in
                if expanded { expandedTop30.insert(key) }
                else { expandedTop30.remove(key) }
            }
        )
    }

    private func relationState(_ news: EditorialRelationEndpoint,
                               _ trend: EditorialRelationEndpoint) -> String? {
        indexedRelationStates[pairKey(news, trend)]
    }

    private func unresolvedKey(_ news: EditorialRelationEndpoint,
                               rank: Int, name: String) -> String {
        let row = top30Trends.indices.contains(rank - 1) ? top30Trends[rank - 1] : nil
        return news.stableIdentity + "↔pending:" + (row?.editorialID ?? name) +
            ":r" + String(row?.revision ?? -1) + ":rank" + String(rank)
    }

    private func unresolvedCount(for news: EditorialRelationEndpoint) -> Int {
        (1...min(30, top30Names.count)).filter { rank in
            unresolvedTop30Selections.contains(unresolvedKey(
                news, rank: rank, name: top30Names[rank - 1]))
        }.count
    }

    private func changedTrends(for news: EditorialRelationEndpoint)
        -> (links: [EditorialRelationEndpoint], unlinks: [EditorialRelationEndpoint]) {
        // Every displayed news episode with a real ID/revision is selectable.
        // Missing fingerprints are optional: the Site validates exact identity.
        // Include current Top30 endpoints even when absent from private snapshot.
        let endpoints = Array(indexedTrendEndpoints.values) +
            (model.snapshot?.trends ?? []) + canonicalRelations.map(\.trend)
        var preferred: [String: EditorialRelationEndpoint] = [:]
        for trend in endpoints {
            let key = EditorialRelationsPolicy.newsKey(
                id: trend.id, revision: trend.revision)
            if preferred[key] == nil ||
               (preferred[key]?.episodeFingerprint.isEmpty == true &&
                !trend.episodeFingerprint.isEmpty) {
                preferred[key] = trend
            }
        }
        var links: [EditorialRelationEndpoint] = []
        var unlinks: [EditorialRelationEndpoint] = []
        for trend in preferred.values {
            guard let desired = pendingSwitches[pairKey(news, trend)],
                  let action = EditorialRelationsPolicy.actionForSwitch(
                    current: relationState(news, trend), selected: desired) else { continue }
            if action == "link" { links.append(trend) }
            else { unlinks.append(trend) }
        }
        return (links, unlinks)
    }

    @ViewBuilder
    private func newsCard(_ news: EditorialRelationEndpoint) -> some View {
        if filter == "suggested" {
            DisclosureGroup(isExpanded: expansion(news)) {
                Text("Marca las tendencias que quieras asociar. Desmarca las ya vinculadas. Solo se guardan los cambios que hagas.")
                    .font(.footnote).foregroundStyle(.secondary)
                if news.episodeFingerprint.isEmpty {
                    Text("Noticia recuperada del historial por ID y revisión. Puedes marcarla y guardar; el Site debe verificar el episodio y devolver la relación confirmada.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if top30Names.isEmpty {
                    Text("Actualiza el Top 30 para elegir tendencias.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(top30Names.prefix(30).enumerated()), id: \.offset) { index, name in
                    top30Row(news: news, rank: index + 1, name: name)
                }
                // Suggestions outside today's Top30 are kept inspectable.
                let otherSuggestions = rows(for: news).filter { item in
                    !top30Trends.contains {
                        $0.editorialID == item.trend.id &&
                        $0.revision == item.trend.revision &&
                        $0.explanation == item.trend.text
                    }
                }
                if !otherSuggestions.isEmpty {
                    Text("Otras propuestas").font(.subheadline.weight(.semibold))
                    ForEach(otherSuggestions) { item in
                        HStack {
                            Text(item.trend.title).font(.subheadline)
                            Spacer()
                            Button("Descartar") { decide(item, action: "dismiss") }
                                .font(.caption)
                        }
                    }
                }
                let changes = changedTrends(for: news)
                let unresolved = unresolvedCount(for: news)
                if unresolved > 0 {
                    Text("\(unresolved) selecciones pendientes de identidad: la APP permite marcarlas, pero no puede guardarlas como relación hasta que el servidor confirme el episodio exacto. No se enviarán asociaciones por nombre.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button {
                    Task {
                        if !changes.links.isEmpty || !changes.unlinks.isEmpty {
                            let saved = await model.saveSelection(
                                news: news, links: changes.links,
                                unlinks: changes.unlinks, using: github)
                            if saved {
                                for trend in changes.links + changes.unlinks {
                                    pendingSwitches.removeValue(forKey: pairKey(news, trend))
                                }
                            }
                        }
                        if unresolved > 0 {
                            // Reload the authority to see whether new trend
                            // fingerprints are available, but leave selections
                            // staged rather than falsely claiming publication.
                            await model.load(using: github)
                            model.notice = "Las tendencias sin identidad editorial siguen marcadas localmente. El servidor de relaciones debe devolver los 30 episodios para guardarlas con seguridad."
                        }
                    }
                } label: {
                    Label("Guardar: \(changes.links.count) asociar · \(changes.unlinks.count) desasociar · \(unresolved) pendientes",
                          systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.saving || (changes.links.isEmpty &&
                                          changes.unlinks.isEmpty && unresolved == 0))
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(news.title).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    let attached = canonicalRelations.filter {
                        same($0.news, news) && $0.state == "linked"
                    }.count
                    HStack(spacing: 8) {
                        Text("\(attached) vinculadas · Top 30")
                        if let date = EditorialRelationsPolicy.parsedDate(news.listedAt) {
                            Text(date, style: .relative)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label(news.title, systemImage: "newspaper")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                ForEach(rows(for: news)) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.trend.title).font(.subheadline.weight(.medium))
                        Text(item.origin == "manual" ? "Vínculo manual" : "Vínculo automático")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(item.state == "linked" ? "Desvincular" : "Volver a vincular") {
                            decide(item, action: item.state == "linked" ? "unlink" : "link")
                        }.buttonStyle(.bordered).disabled(model.saving)
                    }
                    Divider()
                }
            }.padding(.vertical, 7)
        }
    }

    @ViewBuilder
    private func top30Row(news: EditorialRelationEndpoint,
                          rank: Int, name: String) -> some View {
        let endpoint = currentTrendEndpoint(rank: rank, name: name)
        HStack(spacing: 8) {
            Text(String(rank) + ".").font(.caption).foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            if let trend = endpoint {
                let state = relationState(news, trend)
                let linked = state == "linked"
                let checked = pendingSwitches[pairKey(news, trend)] ?? linked
                Button {
                    toggleSelection(news, trend)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 21))
                            .foregroundStyle(TTTheme.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.subheadline)
                            if pendingSwitches[pairKey(news, trend)] != nil {
                                Text(checked ? "Se asociará al guardar" : "Se desasociará al guardar")
                                    .font(.caption2).foregroundStyle(.orange)
                            } else if state == "suggested" {
                                Text("Propuesta automática").font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if state == "blocked" {
                                Text("No asociada · bloqueada").font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel((checked ? "Desasociar " : "Asociar ") + name)
                .accessibilityValue(checked ? "Asociada" : "No asociada")
                .disabled(model.saving)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 19)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline)
                        Text("Identificador de tendencia pendiente")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func decide(_ item: EditorialRelation, action: String) {
        Task { await model.decide(news: item.news, trend: item.trend, action: action, using: github) }
    }
}

private struct EditorialEndpointPicker: View {
    let title: String
    let endpoints: [EditorialRelationEndpoint]
    let select: (EditorialRelationEndpoint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List(endpoints.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
                $0.text.localizedCaseInsensitiveContains(search) }) { endpoint in
                Button { select(endpoint) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(endpoint.title).font(.headline)
                        if let listedAt = endpoint.listedAt, !listedAt.isEmpty {
                            Text("Última entrada en Listas: " + listedAt)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(endpoint.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }.buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Buscar")
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
