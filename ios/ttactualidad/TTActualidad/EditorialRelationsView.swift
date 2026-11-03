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
    // Keep a possibly accepted command ID for a conscious retry after a timeout.
    private var commands: [String: String] = [:]

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

    func decide(news: EditorialRelationEndpoint, trend: EditorialRelationEndpoint,
                action: String, using github: GitHubEditor) async {
        guard !saving, ["link", "unlink", "dismiss"].contains(action) else { return }
        saving = true
        defer { saving = false }
        let key = [action, news.id, String(news.revision), news.episodeFingerprint,
                   trend.id, String(trend.revision), trend.episodeFingerprint].joined(separator: "|")
        let command = commands[key] ?? UUID().uuidString.lowercased()
        commands[key] = command
        do {
            let body = try JSONEncoder().encode(EditorialRelationDecision(
                action: action, expectedNews: news.identity, expectedTrend: trend.identity,
                commandId: command))
            let (data, status) = try await github.privateEditorialRelationsRequest(
                path: "/v1/decisions", method: "POST", jsonBody: body)
            if status == 409 {
                commands.removeValue(forKey: key)
                await load(using: github)
                throw RelationsError.http(status)
            }
            guard status == 200 else { throw RelationsError.http(status) }
            let receipt = try JSONDecoder().decode(EditorialRelationReceipt.self, from: data)
            guard EditorialRelationsPolicy.confirms(receipt, action: action) else {
                throw RelationsError.unconfirmed
            }
            commands.removeValue(forKey: key)
            await load(using: github)
            notice = action == "link" ? "Relación vinculada en ambos sentidos." :
                "Relación bloqueada para este episodio. El automatismo no volverá a añadirla."
        } catch {
            notice = "No se ha confirmado la decisión: \(error.localizedDescription)"
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = EditorialRelationsModel()
    @State private var filter = "linked"
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
                        Section(filter == "suggested" ? "Solo relaciones dudosas" :
                                filter == "linked" ? "Relaciones confirmadas, incluidas las automáticas" : "Relaciones bloqueadas") {
                            if relations.isEmpty && !model.loading {
                                Text("No hay relaciones en este estado.").foregroundStyle(.secondary)
                            }
                            ForEach(relations) { item in relationRow(item) }
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
            .navigationTitle(scope == nil ? "Relaciones por revisar" : "Relaciones")
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

    private func relationRow(_ item: EditorialRelation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.news.title, systemImage: "newspaper").font(.subheadline.weight(.semibold))
            Label(item.trend.title, systemImage: "chart.line.uptrend.xyaxis").font(.subheadline)
            Text(item.origin == "manual" ? "Decisión manual" : "Detección automática")
                .font(.caption).foregroundStyle(.secondary)
            if !item.reason.isEmpty { Text(item.reason).font(.footnote).foregroundStyle(.secondary) }
            HStack {
                if item.state == "linked" {
                    Button("Desvincular", role: .destructive) { decide(item, action: "unlink") }
                } else {
                    Button(item.state == "blocked" ? "Volver a vincular" : "Vincular") { decide(item, action: "link") }
                    if item.state == "suggested" {
                        Button("Descartar", role: .destructive) { decide(item, action: "dismiss") }
                    }
                }
            }.buttonStyle(.bordered).disabled(model.saving)
        }.padding(.vertical, 5)
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
