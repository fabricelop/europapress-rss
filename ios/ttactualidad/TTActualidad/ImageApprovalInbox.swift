import Combine
import CryptoKit
import SwiftUI
import UIKit

// The original PNG is fetched only from the authenticated private inbox.
// It never uses AsyncImage or a public CDN/cache URL.
private struct ApprovalIdentity: Codable {
    let project: String
    let editorialId: String
    let revision: Int
    let episodeFingerprint: String
    let commandId: String
    let rasterSHA256: String
}

private struct PendingImage: Decodable, Identifiable {
    let id: String
    let identity: ApprovalIdentity
    let title: String
    let editorialText: String
    let createdAt: String
}

private struct PendingImageResponse: Decodable {
    let items: [PendingImage]
}

private struct ApprovalDecision: Encodable {
    let action: String
    let expectedIdentity: ApprovalIdentity
}

private struct DecisionResponse: Decodable {
    let state: String
}

@MainActor
private final class ApprovalInboxModel: ObservableObject {
    @Published private(set) var images: [PendingImage] = []
    @Published private(set) var previews: [String: UIImage] = [:]
    @Published private(set) var loading = false
    @Published private(set) var actionID: String?
    @Published var notice = ""

    func load(using github: GitHubEditor) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let (data, status) = try await github.privateImageInboxRequest(path: "/v1/images")
            guard status == 200 else { throw InboxError.http(status) }
            let items = try JSONDecoder().decode(PendingImageResponse.self, from: data).items
            images = items
            let keys = Set(items.map(\.id))
            previews = previews.filter { keys.contains($0.key) }
            notice = items.isEmpty ? "No hay imágenes pendientes de aprobación." : ""
            for image in items where previews[image.id] == nil {
                await loadOriginal(image, using: github)
            }
        } catch {
            notice = "No se pudo consultar la bandeja privada: \(error.localizedDescription)"
        }
    }

    private func loadOriginal(_ item: PendingImage, using github: GitHubEditor) async {
        do {
            guard item.id.count == 64, item.id.allSatisfy(\.isHexDigit) else { return }
            let (data, status) = try await github.privateImageInboxRequest(
                path: "/v1/images/\(item.id)/original")
            guard status == 200, data.count < 11_000_000 else { return }
            // Never trust a preview with bytes from another raster or revision.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == item.identity.rasterSHA256, let image = UIImage(data: data) else {
                notice = "El original no coincide con la huella registrada. No se aprobará automáticamente."
                return
            }
            previews[item.id] = image
        } catch {
            // A temporarily missing PNG must not erase or approve its card.
        }
    }

    func decide(_ item: PendingImage, action: String, using github: GitHubEditor) async {
        guard actionID == nil, ["approve", "reject"].contains(action) else { return }
        guard previews[item.id] != nil else {
            notice = "Necesitamos comprobar primero el PNG original antes de tomar una decisión."
            return
        }
        actionID = item.id
        defer { actionID = nil }
        do {
            let body = try JSONEncoder().encode(ApprovalDecision(
                action: action, expectedIdentity: item.identity))
            let (data, status) = try await github.privateImageInboxRequest(
                path: "/v1/images/\(item.id)/decision", method: "POST", jsonBody: body)
            guard status == 200 else { throw InboxError.http(status) }
            let response = try JSONDecoder().decode(DecisionResponse.self, from: data)
            guard response.state == (action == "approve" ?
                    "approved_awaiting_publication" : "rejected") else {
                throw InboxError.unexpectedResponse
            }
            images.removeAll { $0.id == item.id }
            previews.removeValue(forKey: item.id)
            notice = action == "approve" ?
                "Aprobada. Pendiente de comprobar su publicación en la APP y Sites." :
                "Rechazada. Solo se ha retirado de la bandeja; original conservado."
        } catch {
            notice = "No se ha confirmado la decisión: \(error.localizedDescription)"
            // Leave card visible, including original, for a deliberate retry.
        }
    }

    private enum InboxError: LocalizedError {
        case http(Int), unexpectedResponse
        var errorDescription: String? {
            switch self {
            case .http(401): return "Vincula tu cuenta GitHub de editor."
            case .http(409): return "La ficha, revisión o imagen ha cambiado. Actualiza la bandeja."
            case .http(let status): return "El servidor devolvió \(status)."
            case .unexpectedResponse: return "La confirmación del servidor no es válida."
            }
        }
    }
}

struct ImageApprovalInbox: View {
    @ObservedObject var github: GitHubEditor
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ApprovalInboxModel()

    var body: some View {
        NavigationStack {
            Group {
                if !github.imageInboxConfigured {
                    ContentUnavailableView(
                        "Bandeja pendiente de conexión",
                        systemImage: "lock.shield",
                        description: Text("El servicio privado aún no está configurado. Ninguna imagen nueva puede publicarse desde aquí."))
                } else if !github.authenticated {
                    ContentUnavailableView(
                        "Conecta GitHub",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Las imágenes pendientes solo pueden verse con tu cuenta autorizada."))
                } else {
                    List {
                        if !model.notice.isEmpty {
                            Section {
                                Text(model.notice)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.images) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(item.identity.project == "ttendencias" ? "TTendencias" : "TTiTTulares")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .font(.headline)
                                Text(item.editorialText)
                                    .font(.subheadline)
                                    .textSelection(.enabled)
                                if let original = model.previews[item.id] {
                                    Image(uiImage: original)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: .infinity)
                                        .accessibilityLabel("PNG original de \(item.title)")
                                } else {
                                    Label("Original pendiente de verificación", systemImage: "photo.badge.exclamationmark")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text("Ficha \(item.identity.editorialId) · revisión \(item.identity.revision)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Button("Aprobar") {
                                        Task { await model.decide(item, action: "approve", using: github) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                    Button("Rechazar") {
                                        Task { await model.decide(item, action: "reject", using: github) }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                }
                                .disabled(model.actionID != nil || model.previews[item.id] == nil)
                            }
                            .padding(.vertical, 7)
                        }
                        if !model.loading && model.images.isEmpty && model.notice.isEmpty {
                            Text("No hay imágenes pendientes.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .refreshable { await model.load(using: github) }
                    .overlay {
                        if model.loading && model.images.isEmpty { ProgressView("Consultando bandeja privada…") }
                    }
                }
            }
            .navigationTitle("Imágenes pendientes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.load(using: github) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!github.imageInboxConfigured || !github.authenticated || model.loading)
                    .accessibilityLabel("Actualizar imágenes pendientes")
                }
            }
            .task {
                if github.imageInboxConfigured && github.authenticated {
                    await model.load(using: github)
                }
            }
        }
    }
}