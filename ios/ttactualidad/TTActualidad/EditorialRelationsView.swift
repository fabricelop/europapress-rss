import Combine
import SwiftUI

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
            issues.append("No se pudieron cargar las identidades de relaciones: \(error.localizedDescription)")
        }
        do {
            historicalNews = try await datedHistory
        } catch {
            issues.append("No se pudieron recuperar las noticias históricas: \(error.localizedDescription)")
        }
        if !issues.isEmpty { notice = issues.joined(separator: ". ") }
    }

    private func postDecision(news: EditorialRelationEndpoint,
                              trend: EditorialRelationEndpoint,
                              action: String, using github: GitHubEditor) async throws {
        let key = [action, news.id, String(news.revision), news.episodeFingerprint,
                   trend.id, String(trend.revision), trend.episodeFingerprint].joined(separator: "|")
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
        commands.removeValue(forKey: key)
        UserDefaults.standard.set(commands, forKey: commandStorageKey)
    }

    func decide(news: EditorialRelationEndpoint, trend: EditorialRelationEndpoint,
                action: String, using github: GitHubEditor) async {
        guard !saving, ["link", "unlink", "dismiss"].contains(action) else { return }
        saving = true
        defer { saving = false }
        do {
            try await postDecision(news: news, trend: trend, action: action, using: github)
            await load(using: github)
            notice = action == "link" ? "Relación vinculada en ambos sentidos." :
                "Relación bloqueada para este episodio. El automatismo no volverá a añadirla."
        } catch {
            if let failure = error as? RelationsError, case .http(409) = failure {
                await load(using: github)
            }
            notice = "No se ha confirmado la decisión: \(error.localizedDescription)"
        }
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
        let completed = "\(linked) asociadas · \(unlinked) desasociadas"
        if let errorMessage {
            notice = completed + ". Hay cambios sin confirmar: " +
                errorMessage + ". Revisa las marcas antes de reintentar."
        } else {
            notice = completed + " para «\(news.title)»."
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
    @State private var lookbackHours = 12
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

    private var canonicalRelations: [EditorialRelation] {
        EditorialRelationsPolicy.canonical(model.snapshot?.items ?? [])
    }

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

    private var allNewsChoices: [EditorialRelationEndpoint] {
        // The server returns linkable episodes; GitHub returns extra recent
        // display-only episodes (fingerprint empty). Combine by exact ID and
        // revision, preferring any server-issued fingerprint for decisions.
        let candidates = (model.snapshot?.news ?? []) +
            canonicalRelations.map(\.news) + model.historicalNews
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
                    title: preferred.title.isEmpty ? row.title : preferred.title,
                    text: preferred.text.isEmpty ? row.text : preferred.text,
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

    private var fallbackDates: [String: Date] {
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

    private var recentNewsChoices: [EditorialRelationEndpoint] {
        EditorialRelationsPolicy.recentNews(
            allNewsChoices, hours: lookbackHours, now: Date(),
            fallbackDates: fallbackDates, hidden: hiddenNews)
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
    }

    private func restore(_ news: EditorialRelationEndpoint) {
        hiddenNews.remove(news.stableIdentity)
        hiddenNews.remove(EditorialRelationsPolicy.newsKey(id: news.id, revision: news.revision))
        UserDefaults.standard.set(Array(hiddenNews).sorted(), forKey: hiddenStorageKey)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !github.authenticated {
                    ContentUnavailableView("Conecta GitHub", systemImage: "lock.shield",
                        description: Text("Las relaciones se gestionan solo con tu cuenta de editor."))
                } else {
                    List {
                        if let scope {
                            Section("Ficha seleccionada") {
                                Text(scopedEndpoint?.title ?? scope.title).font(.headline)
                                if model.snapshot != nil && scopedEndpoint == nil {
                                    Text("Esta ficha no está disponible con esa revisión. Actualiza la APP para consultar su estado actual.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !model.notice.isEmpty {
                            Section { Text(model.notice).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
                        }
                        Section {
                            Picker("Estado de relaciones", selection: $filter) {
                                Text("Por revisar").tag("suggested")
                                Text("Confirmadas").tag("linked")
                                Text("Bloqueadas").tag("blocked")
                            }.pickerStyle(.segmented)
                        }
                        if filter == "suggested" && scope == nil {
                            Section("Ventana de noticias") {
                                Picker("Últimas horas", selection: $lookbackHours) {
                                    Text("12 horas").tag(12)
                                    Text("24 horas").tag(24)
                                }.pickerStyle(.segmented)
                                Text("Se incluyen noticias aunque ya hayan salido de Listas. Solo se aplican fechas editoriales verificables; si falta la fecha, puedes localizar la noticia en «Elegir otra noticia».")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Section(filter == "suggested" ? "Noticias recientes · \(newsGroups.count)" :
                                filter == "linked" ? "Relaciones confirmadas por noticia" :
                                "Relaciones bloqueadas por noticia") {
                            if newsGroups.isEmpty && !model.loading {
                                Text(filter == "suggested" ?
                                     "No hay noticias con fecha confirmada en esta ventana. Prueba 24 horas o «Elegir otra noticia»." :
                                     "No hay noticias con relaciones en este estado.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(newsGroups, id: \.stableIdentity) { news in
                                newsCard(news)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if filter == "suggested" && scope == nil {
                                            Button {
                                                hide(news)
                                            } label: {
                                                Label("Ocultar de esta lista", systemImage: "eye.slash")
                                            }.tint(.gray)
                                        }
                                    }
                            }
                        }
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
                    .refreshable { await model.load(using: github) }
                    .overlay { if model.loading && model.snapshot == nil { ProgressView("Consultando relaciones…") } }
                    .disabled(model.saving)
                }
            }
            .navigationTitle(scope == nil ? "Relaciones por noticia" : "Relaciones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.load(using: github) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.disabled(model.loading || model.saving || !github.authenticated)
                    .accessibilityLabel("Actualizar relaciones")
                }
            }
            .task { if github.authenticated { await model.load(using: github) } }
            .sheet(item: $picker) { route in
                EditorialEndpointPicker(
                    title: route.project == "ttittulares" ? "Seleccionar noticia" : "Seleccionar tendencia",
                    endpoints: route.project == "ttittulares" ? allNewsChoices : model.snapshot?.trends ?? []) { endpoint in
                        selectedNews = endpoint
                        picker = nil
                    }
            }
        }.preferredColorScheme(.dark)
    }

    private func same(_ left: EditorialRelationEndpoint,
                      _ right: EditorialRelationEndpoint) -> Bool {
        left.id == right.id && left.revision == right.revision &&
            left.episodeFingerprint == right.episodeFingerprint
    }

    // One card per actual news episode, regardless of how many trend proposals
    // or server refreshes refer to it.
    private var newsGroups: [EditorialRelationEndpoint] {
        if filter == "suggested" && scope == nil {
            var result = recentNewsChoices
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

    private func rows(for news: EditorialRelationEndpoint) -> [EditorialRelation] {
        var seen = Set<String>()
        return relations.filter {
            same($0.news, news) && seen.insert($0.trend.stableIdentity).inserted
        }
    }

    private func pairKey(_ news: EditorialRelationEndpoint,
                         _ trend: EditorialRelationEndpoint) -> String {
        news.stableIdentity + "↔" + trend.stableIdentity
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
        canonicalRelations.first {
            same($0.news, news) && same($0.trend, trend)
        }?.state
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
        // A display-only historical row does not have the Sites-issued
        // fingerprint required to authorize or verify a decision.
        guard !news.episodeFingerprint.isEmpty else { return ([], []) }
        let endpoints = (model.snapshot?.trends ?? []) + canonicalRelations.map(\.trend)
        var seen = Set<String>()
        var links: [EditorialRelationEndpoint] = []
        var unlinks: [EditorialRelationEndpoint] = []
        for trend in endpoints {
            guard seen.insert(trend.stableIdentity).inserted,
                  let desired = pendingSwitches[pairKey(news, trend)],
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
                    Text("Noticia recuperada del historial. Pendiente de identidad del servidor de relaciones: puedes marcar tendencias, pero guardarlas requiere que el servidor reconozca esta noticia.")
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
        let endpoints = (model.snapshot?.trends ?? []) + canonicalRelations.map(\.trend)
        // Never link a stale trend with the same display name. The actual
        // current Top30 row must carry the same exact editorial episode.
        let row = top30Trends.indices.contains(rank - 1) ? top30Trends[rank - 1] : nil
        let endpoint = endpoints.first {
            guard let row else { return false }
            return row.name == name &&
                $0.id == row.editorialID &&
                $0.revision == row.revision &&
                $0.text == row.explanation &&
                !$0.episodeFingerprint.isEmpty
        }
        HStack(spacing: 8) {
            Text(String(rank) + ".").font(.caption).foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            if let trend = endpoint, !news.episodeFingerprint.isEmpty {
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
                let staged = unresolvedTop30Selections.contains(
                    unresolvedKey(news, rank: rank, name: name))
                Button {
                    let key = unresolvedKey(news, rank: rank, name: name)
                    if staged { unresolvedTop30Selections.remove(key) }
                    else { unresolvedTop30Selections.insert(key) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: staged ? "checkmark.square.fill" : "square")
                            .font(.system(size: 21))
                            .foregroundStyle(staged ? TTTheme.teal : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.subheadline)
                            Text("Identidad pendiente · selección local")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel((staged ? "Desmarcar " : "Marcar ") + name)
                .accessibilityValue(staged ? "Pendiente de confirmar" : "No seleccionada")
                .disabled(model.saving)
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
