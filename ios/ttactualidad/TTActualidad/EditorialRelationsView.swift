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
        do {
            let (data, status) = try await github.privateEditorialRelationsRequest(path: "/v1/snapshot")
            guard status == 200 else { throw RelationsError.http(status) }
            snapshot = try JSONDecoder().decode(EditorialRelationsSnapshot.self, from: data)
        } catch {
            notice = "No se pudieron actualizar las relaciones: \(error.localizedDescription)"
        }
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
            if case RelationsError.http(409) = error { await load(using: github) }
            notice = "No se ha confirmado la decisión: \(error.localizedDescription)"
        }
    }

    // One save action per news card; every selected pair receives its own
    // episode-checked, idempotent server decision. Refresh just once at end.
    func linkSelected(news: EditorialRelationEndpoint,
                      trends: [EditorialRelationEndpoint],
                      using github: GitHubEditor) async {
        guard !saving, !trends.isEmpty else { return }
        saving = true
        defer { saving = false }
        var confirmed = 0
        var lastError: String?
        var seen = Set<String>()
        for trend in trends {
            let identity = [trend.id, String(trend.revision),
                            trend.episodeFingerprint].joined(separator: "|")
            guard seen.insert(identity).inserted else { continue }
            do {
                try await postDecision(news: news, trend: trend, action: "link",
                                       using: github)
                confirmed += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        await load(using: github)
        if let lastError {
            notice = "\(confirmed) vínculos confirmados. Hay vínculos sin confirmar: \(lastError). Puedes reintentar sin duplicar órdenes."
        } else {
            notice = "\(confirmed) vínculos guardados y confirmados para «\(news.title)»."
        }
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = EditorialRelationsModel()
    @State private var filter = "suggested"
    @State private var selectedPairs = Set<String>()
    @State private var expandedTop30 = Set<String>()
    @State private var showManualLinking = false
    @State private var search = ""
    @State private var selectedNews: EditorialRelationEndpoint?
    @State private var selectedTrend: EditorialRelationEndpoint?
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

    private var relations: [EditorialRelation] {
        (model.snapshot?.items ?? []).filter { item in
            guard item.state == filter else { return false }
            guard let scope else { return true }
            let endpoint = scope.project == "ttittulares" ? item.news : item.trend
            return EditorialRelationsPolicy.matches(endpoint, id: scope.id, revision: scope.revision)
        }
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
                        Section(filter == "suggested" ? "Noticias con tendencias propuestas" :
                                filter == "linked" ? "Relaciones confirmadas por noticia" :
                                "Relaciones bloqueadas por noticia") {
                            if newsGroups.isEmpty && !model.loading {
                                Text("No hay noticias con relaciones en este estado.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(newsGroups, id: \.stableIdentity) { news in
                                newsCard(news)
                            }
                        }
                        Section {
                            DisclosureGroup("Vincular otra ficha (opcional)", isExpanded: $showManualLinking) {
                                Text("Las relaciones claras se presentan directamente como confirmadas. Las ambiguas se revisan por separado. Una decisión afecta a ambos sentidos y no modifica publicaciones ni imágenes.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if scope == nil {
                                Button { picker = EndpointPickerRoute(project: "ttittulares") } label: {
                                    Label(selectedNews?.title ?? "Seleccionar noticia", systemImage: "newspaper")
                                }
                                Button { picker = EndpointPickerRoute(project: "ttendencias") } label: {
                                    Label(selectedTrend?.title ?? "Seleccionar tendencia", systemImage: "chart.line.uptrend.xyaxis")
                                }
                                Button("Vincular selección") {
                                    guard let news = selectedNews, let trend = selectedTrend else { return }
                                    Task { await model.decide(news: news, trend: trend, action: "link", using: github) }
                                }.disabled(selectedNews == nil || selectedTrend == nil || model.saving)
                            } else if let endpoint = scopedEndpoint, let scope {
                                TextField(scope.project == "ttittulares" ? "Buscar tendencia" : "Buscar noticia", text: $search)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                ForEach(candidates) { candidate in
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(candidate.title).font(.subheadline.weight(.semibold))
                                        Text(candidate.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                        Button("Vincular") {
                                            let news = scope.project == "ttittulares" ? endpoint : candidate
                                            let trend = scope.project == "ttendencias" ? endpoint : candidate
                                            Task { await model.decide(news: news, trend: trend, action: "link", using: github) }
                                        }.disabled(model.saving)
                                    }
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
                    endpoints: route.project == "ttittulares" ? model.snapshot?.news ?? [] : model.snapshot?.trends ?? []) { endpoint in
                        if route.project == "ttittulares" { selectedNews = endpoint }
                        else { selectedTrend = endpoint }
                        picker = nil
                    }
            }
        }.preferredColorScheme(.dark)
    }

    private var candidates: [EditorialRelationEndpoint] {
        guard let scope, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let all = scope.project == "ttittulares" ? model.snapshot?.trends ?? [] : model.snapshot?.news ?? []
        return all.filter { $0.title.localizedCaseInsensitiveContains(search) ||
            $0.text.localizedCaseInsensitiveContains(search) }
    }

    private func same(_ left: EditorialRelationEndpoint,
                      _ right: EditorialRelationEndpoint) -> Bool {
        left.id == right.id && left.revision == right.revision &&
            left.episodeFingerprint == right.episodeFingerprint
    }

    // One card per actual news episode, regardless of how many trend proposals
    // or server refreshes refer to it.
    private var newsGroups: [EditorialRelationEndpoint] {
        var seen = Set<String>()
        return relations.compactMap { item in
            let news = item.news
            return seen.insert(news.stableIdentity).inserted ? news : nil
        }
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
        if selectedPairs.contains(key) { selectedPairs.remove(key) }
        else { selectedPairs.insert(key) }
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
        model.snapshot?.items.first {
            same($0.news, news) && same($0.trend, trend)
        }?.state
    }

    private func selectedTrends(for news: EditorialRelationEndpoint)
        -> [EditorialRelationEndpoint] {
        var seen = Set<String>()
        let snapshot = model.snapshot
        let endpoints = (snapshot?.trends ?? []) + (snapshot?.items ?? []).map(\.trend)
        return endpoints.filter { trend in
            selectedPairs.contains(pairKey(news, trend)) &&
                relationState(news, trend) != "linked" &&
                relationState(news, trend) != "blocked" &&
                seen.insert(trend.stableIdentity).inserted
        }
    }

    private func newsCard(_ news: EditorialRelationEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(news.title, systemImage: "newspaper")
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            ForEach(rows(for: news)) { item in
                if filter == "suggested" {
                    Button {
                        toggleSelection(news, item.trend)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedPairs.contains(pairKey(news, item.trend))
                                  ? "checkmark.square.fill" : "square")
                                .font(.system(size: 22))
                                .foregroundStyle(TTTheme.teal)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.trend.title).font(.subheadline.weight(.medium))
                                if !item.reason.isEmpty {
                                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Seleccionar tendencia " + item.trend.title)
                    .accessibilityValue(selectedPairs.contains(pairKey(news, item.trend))
                                        ? "Seleccionada" : "No seleccionada")
                    .disabled(model.saving)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.trend.title).font(.subheadline.weight(.medium))
                        Text(item.origin == "manual" ? "Vínculo manual" : "Vínculo automático")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(item.state == "linked" ? "Desvincular" : "Volver a vincular") {
                            decide(item, action: item.state == "linked" ? "unlink" : "link")
                        }.buttonStyle(.bordered).disabled(model.saving)
                    }
                }
                Divider()
            }
            if filter == "suggested" {
                DisclosureGroup(isExpanded: expansion(news)) {
                    if top30Names.isEmpty {
                        Text("Actualiza el Top 30 para elegir otras tendencias.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(top30Names.prefix(30).enumerated()), id: \.offset) { index, name in
                        top30Row(news: news, rank: index + 1, name: name)
                    }
                } label: {
                    Label("Añadir otras tendencias · Top 30", systemImage: "chevron.down.circle")
                        .font(.subheadline.weight(.medium))
                }
                Button {
                    let trends = selectedTrends(for: news)
                    Task { await model.linkSelected(news: news, trends: trends, using: github) }
                } label: {
                    Label("Guardar vínculos seleccionados (\(selectedTrends(for: news).count))",
                          systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.saving || selectedTrends(for: news).isEmpty)
            }
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func top30Row(news: EditorialRelationEndpoint,
                          rank: Int, name: String) -> some View {
        let endpoint = model.snapshot?.trends.first {
            TrendImportance.key($0.title) == TrendImportance.key(name)
        }
        HStack(spacing: 8) {
            Text(String(rank) + ".").font(.caption).foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            if let trend = endpoint {
                let state = relationState(news, trend)
                if state == "linked" {
                    Label(name + " · ya vinculada", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if state == "suggested" {
                    Text(name + " · propuesta arriba").font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if state == "blocked" {
                    Text(name + " · bloqueada").font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        toggleSelection(news, trend)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selectedPairs.contains(pairKey(news, trend))
                                  ? "checkmark.square.fill" : "square")
                                .font(.system(size: 21))
                                .foregroundStyle(TTTheme.teal)
                            Text(name).font(.subheadline)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Seleccionar tendencia " + name)
                    .accessibilityValue(selectedPairs.contains(pairKey(news, trend))
                                        ? "Seleccionada" : "No seleccionada")
                    .disabled(model.saving)
                }
            } else {
                Text(name + " · pendiente de identidad editorial")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
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
