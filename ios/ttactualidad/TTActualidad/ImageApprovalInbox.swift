import Combine
import CryptoKit
import SwiftUI
import UIKit
import ImageIO

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
    let editorialAt: String?
    let state: String?
}

private struct PendingImageResponse: Decodable {
    let items: [PendingImage]
    let hasMore: Bool?
    let nextCursor: String?
}

private struct ApprovalDecision: Encodable {
    let action: String
    let expectedIdentity: ApprovalIdentity
}

private struct DecisionResponse: Decodable {
    let state: String
    let appVerified: Bool?
    let sitesVerified: Bool?
}

// All original PNGs accepted by the private inbox remain visible for the
// editor's decision, even when their trend falls outside today's Top 30 or
// their news leaves Listas. The private backend validates the exact episode
// again before ANY approval or publication. Neither a radar outage nor a
// stale GitHub snapshot may turn a real pending image into an empty inbox.
private enum ApprovalInboxScope {
    static func visible(_ items: [PendingImage]) -> [PendingImage] {
        var seen = Set<String>()
        return items.sorted { $0.createdAt > $1.createdAt }.filter { item in
            let identity = item.identity
            guard ["ttendencias", "ttittulares"].contains(identity.project) else { return false }
            let episode = identity.editorialId + ":r" + String(identity.revision)
            let key = identity.project + ":" + episode
            // Reserve newest exact episode even if it was already decided:
            // a superseded pending original must not reappear.
            guard seen.insert(key).inserted else { return false }
            return ["pending", "pending_approval"].contains(
                (item.state ?? "pending").lowercased())
        }
    }
}

@MainActor
private final class ApprovalInboxModel: ObservableObject {
    // Shared across sheet openings: in-flight decisions keep running and
    // remain hidden if the editor closes and reopens the inbox.
    static let shared = ApprovalInboxModel()
    @Published private(set) var images: [PendingImage] = []
    @Published private(set) var previews: [String: UIImage] = [:]
    @Published private(set) var loading = false
    @Published private(set) var processingIDs = Set<String>()
    @Published var notice = ""
    // A successful receipt must not reappear during an eventually-consistent
    // refresh, but a failed decision always restores its original card.
    private var completedIDs = Set<String>()
    // A server-acknowledged decision cannot be forgotten on next app launch.
    // Only exact original ID + SHA + episode may be suppressed, never a name.
    private struct AcceptedReceipt: Codable {
        var imageID: String
        var rasterSHA256: String
        var episode: String
        var state: String
        var acceptedAt: Date
    }
    private let acceptedKey = "TTActualidad.privateImageInbox.accepted.v1"
    private var acceptedReceipts: [String: AcceptedReceipt] = [:]
    private var decisionTail: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: acceptedKey),
           let saved = try? JSONDecoder().decode([String: AcceptedReceipt].self, from: data) {
            acceptedReceipts = saved.filter { entry in
                // Store only exact original SHA/identity; no image bytes or OAuth data.
                entry.value.imageID == entry.key && entry.key.count == 64 &&
                entry.value.rasterSHA256.count == 64 &&
                entry.value.acceptedAt <= Date().addingTimeInterval(60)
            }
        }
    }

    private func accepted(_ item: PendingImage) -> Bool {
        guard let receipt = acceptedReceipts[item.id] else { return false }
        return receipt.rasterSHA256 == item.identity.rasterSHA256 &&
            receipt.episode == item.identity.project + ":" + item.identity.editorialId +
                ":r" + String(item.identity.revision)
    }

    private func markAccepted(_ item: PendingImage, state: String) {
        // Accepted does NOT imply published: approved_awaiting_publication stays
        // distinguishable while it is removed from the actionable approval queue.
        let episode = item.identity.project + ":" + item.identity.editorialId +
            ":r" + String(item.identity.revision)
        acceptedReceipts[item.id] = AcceptedReceipt(
            imageID: item.id, rasterSHA256: item.identity.rasterSHA256,
            episode: episode, state: state, acceptedAt: Date())
        // Bounded retention without discarding decisions during normal refresh.
        if acceptedReceipts.count > 4000 {
            let keep = acceptedReceipts.values.sorted { $0.acceptedAt > $1.acceptedAt }
                .prefix(3500)
            acceptedReceipts = Dictionary(uniqueKeysWithValues: keep.map { ($0.imageID, $0) })
        }
        if let data = try? JSONEncoder().encode(acceptedReceipts) {
            UserDefaults.standard.set(data, forKey: acceptedKey)
        }
        completedIDs.insert(item.id)
        images.removeAll { $0.id == item.id }
    }

    @Published private(set) var pageDiagnostics = ""

    func load(using github: GitHubEditor) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            // Read every page with the server's opaque chronological cursor.
            // A server without pagination must not be misreported as complete.
            let (data, status) = try await github.privateImageInboxRequest(path: "/v1/images?limit=20")
            guard status == 200 else { throw InboxError.http(status) }
            var page = try JSONDecoder().decode(PendingImageResponse.self, from: data)
            var received = page.items
            // Render the first authenticated page immediately. With hundreds
            // of retained records, waiting for every cursor made a healthy
            // inbox look blank for the whole pagination round trip.
            images = ApprovalInboxScope.visible(received).filter {
                !processingIDs.contains($0.id) && !completedIDs.contains($0.id) && !accepted($0)
            }
            pageDiagnostics = "Consultando más imágenes privadas… " + String(received.count) + " leídas."
            let supportsPagination = page.hasMore != nil
            var seenCursors = Set<String>()
            var incomplete = false
            while page.hasMore == true {
                guard let cursor = page.nextCursor, !cursor.isEmpty,
                      seenCursors.insert(cursor).inserted else {
                    incomplete = true
                    break
                }
                do {
                    var query = URLComponents()
                    query.queryItems = [URLQueryItem(name: "before", value: cursor)]
                    guard let encoded = query.percentEncodedQuery else {
                        incomplete = true
                        break
                    }
                    let (nextData, nextStatus) = try await github.privateImageInboxRequest(
                        path: "/v1/images?limit=20&" + encoded)
                    guard nextStatus == 200 else { throw InboxError.http(nextStatus) }
                    page = try JSONDecoder().decode(PendingImageResponse.self, from: nextData)
                    received.append(contentsOf: page.items)
                    // Keep the list responsive while the remaining pages arrive.
                    images = ApprovalInboxScope.visible(received).filter {
                        !processingIDs.contains($0.id) && !completedIDs.contains($0.id) && !accepted($0)
                    }
                    pageDiagnostics = "Consultando más imágenes privadas… " + String(received.count) + " leídas."
                } catch {
                    // A late page failure must not erase originals already
                    // returned by the authenticated private service.
                    incomplete = true
                    break
                }
            }
            // Historical pending images do NOT require a live Top 30 lookup.
            let items = ApprovalInboxScope.visible(received)
            pageDiagnostics = "Servidor: " + String(received.count) +
                " imágenes consultadas · " + String(items.count) +
                " pendientes recibidas." +
                (incomplete || !supportsPagination ?
                    " Consulta parcial: vuelve a actualizar para completar páginas." : "")
            images = items.filter {
                !processingIDs.contains($0.id) && !completedIDs.contains($0.id) && !accepted($0)
            }
            let keys = Set(items.map(\.id))
            previews = previews.filter { keys.contains($0.key) }
            let stillAwaiting = received.filter { accepted($0) }.count
            notice = items.isEmpty && stillAwaiting == 0 ?
                "No hay originales pendientes entre las páginas consultadas." :
                (stillAwaiting > 0 ? String(stillAwaiting) +
                 " original(es) con decisión previa aceptada, ocultos de la cola de aprobación." : "")
            for image in items.prefix(4) where previews[image.id] == nil {
                await loadOriginal(image, using: github)
            }
        } catch {
            // Fail closed on source/pagination errors; do not show stale approvals.
            images = []
            previews = [:]
            pageDiagnostics = ""
            notice = "No se pudo comprobar completamente la bandeja privada: \(error.localizedDescription)"
        }
    }

    func loadOriginal(_ item: PendingImage, using github: GitHubEditor) async {
        do {
            guard previews[item.id] == nil, item.id.count == 64, item.id.allSatisfy(\.isHexDigit) else { return }
            let (data, status) = try await github.privateImageInboxRequest(
                path: "/v1/images/\(item.id)/original")
            guard status == 200, data.count < 11_000_000 else { return }
            // Never trust a preview with bytes from another raster or revision.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == item.identity.rasterSHA256,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else {
                notice = "El original no coincide con la huella registrada. No se aprobará automáticamente."
                return
            }
            if previews.count >= 8, let oldest = previews.keys.first { previews.removeValue(forKey: oldest) }
            previews[item.id] = UIImage(cgImage: thumbnail)
        } catch {
            // A temporarily missing PNG must not erase or approve its card.
        }
    }

    // The original belongs to an exact historical editorial episode even
    // after leaving Listas. Preserve the original SHA and use the same
    // editor-authorized GitHub association as "Añadir imagen" if the existing
    // private publisher is temporarily unable to complete the decision.
    private func associateVerifiedOriginalInGitHub(
        _ item: PendingImage, using github: GitHubEditor
    ) async throws -> URL {
        guard item.identity.rasterSHA256.count == 64,
              item.identity.rasterSHA256.allSatisfy(\.isHexDigit) else {
            throw InboxError.unexpectedResponse
        }
        let (original, result) = try await github.privateImageInboxRequest(
            path: "/v1/images/\(item.id)/original")
        guard result == 200,
              original.count > 24, original.count <= 8_000_000,
              original.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              SHA256.hash(data: original).map({ String(format: "%02x", $0) }).joined()
                == item.identity.rasterSHA256 else {
            throw InboxError.unexpectedResponse
        }
        return try await github.associateManualImageInGitHub(
            project: item.identity.project,
            editorialID: item.identity.editorialId,
            revision: item.identity.revision,
            editorialText: item.editorialText, png: original)
    }

    // No await before hiding a card. This method is called directly by the
    // button on the main actor; each tap immediately exposes the next image.
    // The private API and the GitHub mirror run in a serial background queue.
    func decide(_ item: PendingImage, action: String, using github: GitHubEditor) {
        guard ["approve", "reject"].contains(action),
              !processingIDs.contains(item.id),
              !completedIDs.contains(item.id),
              images.contains(where: { $0.id == item.id }) else { return }
        guard previews[item.id] != nil else {
            notice = "Necesitamos comprobar primero el PNG original antes de tomar una decisión."
            return
        }
        processingIDs.insert(item.id)
        images.removeAll { $0.id == item.id }
        notice = "Decisión en curso · " + String(processingIDs.count) +
                 " pendiente(s). Puedes pasar a la siguiente imagen."

        // Safe one-at-a-time backend write, but zero UI waiting. Keep a strong
        // reference until completion even if the sheet is dismissed.
        let previous = decisionTail
        decisionTail = Task {
            await previous?.value
            await persistDecision(item, action: action, using: github)
        }
        // Prefetch the next original right away, without waiting for POST.
        for next in images.prefix(4) where previews[next.id] == nil {
            Task { await loadOriginal(next, using: github) }
        }
    }

    private func restore(_ item: PendingImage) {
        // Server/association failure: never pretend the image was approved.
        // Keep the exact original/identity available for explicit retry.
        if !images.contains(where: { $0.id == item.id }) &&
           !completedIDs.contains(item.id) {
            images.insert(item, at: 0)
        }
    }

    private func persistDecision(_ item: PendingImage, action: String,
                                 using github: GitHubEditor) async {
        defer { processingIDs.remove(item.id) }
        do {
            let body = try JSONEncoder().encode(ApprovalDecision(
                action: action, expectedIdentity: item.identity))
            let (data, status) = try await github.privateImageInboxRequest(
                path: "/v1/images/\(item.id)/decision", method: "POST", jsonBody: body)
            if status != 200 {
                // Preserve the existing immutable-PNG GitHub fallback. It is
                // NOT equivalent to an APP+Site receipt: restore for retry.
                if action == "approve", [404, 409, 503].contains(status) {
                    _ = try await associateVerifiedOriginalInGitHub(item, using: github)
                    await SiteAIImageCatalog.invalidateCache()
                    await NewsAIImageCatalog.invalidateCache()
                    notice = "Original vinculado en GitHub, pero APP/Site aún no " +
                             "confirma esta aprobación (HTTP " + String(status) +
                             "). La imagen vuelve para reintentar."
                    restore(item)
                    return
                }
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = payload?["error"] as? String ?? payload?["code"] as? String
                throw InboxError.decisionHTTP(status, code)
            }
            let response = try JSONDecoder().decode(DecisionResponse.self, from: data)
            if action == "approve" && response.state == "approved_awaiting_publication" {
                // The authoritative service accepted the editor's approval.
                // Do not send the SAME approval again while its publisher runs.
                // Not claimed as 'published': that needs both verification flags.
                markAccepted(item, state: response.state)
                previews.removeValue(forKey: item.id)
                notice = "Aprobación aceptada por el servidor. APP/Site aún pendiente de " +
                         "publicación; no volverá a pedirte aprobar el mismo PNG."
                return
            }
            if action == "approve" && response.state == "published" &&
               !(response.appVerified == true && response.sitesVerified == true) {
                // A 200/published without full proof is NOT success. Preserve an
                // audit state but never duplicate the irreversible approval tap.
                markAccepted(item, state: "published_unverified")
                previews.removeValue(forKey: item.id)
                notice = "El servidor recibió la decisión, pero falta verificar APP/Site. " +
                         "No se repetirá la aprobación; revisa la publicación."
                return
            }
            guard response.state == (action == "approve" ? "published" : "rejected"),
                  action != "approve" || (response.appVerified == true &&
                                          response.sitesVerified == true) else {
                throw InboxError.unexpectedResponse
            }
            markAccepted(item, state: response.state)
            previews.removeValue(forKey: item.id)
            if action == "approve" {
                await SiteAIImageCatalog.invalidateCache()
                await NewsAIImageCatalog.invalidateCache()
                // Same verified PNG and exact editorial identity; a failure
                // here must not undo a confirmed APP/Site approval.
                do {
                    _ = try await associateVerifiedOriginalInGitHub(item, using: github)
                    notice = "Aprobada en APP/Site y asociada en GitHub para X."
                } catch {
                    notice = "Aprobada en APP/Site, pero falta el espejo IA para X: " +
                             error.localizedDescription
                }
            } else {
                notice = "Rechazada. Original conservado; bandeja actualizada."
            }
        } catch {
            notice = "Decisión no confirmada: " + error.localizedDescription +
                     ". Se ha restaurado la imagen para reintentar."
            restore(item)
        }
    }

    private enum InboxError: LocalizedError {
        case http(Int), decisionHTTP(Int, String?), unexpectedResponse
        var errorDescription: String? {
            switch self {
            case .http(401), .decisionHTTP(401, _):
                return "Vincula tu cuenta GitHub de editor."
            case .decisionHTTP(409, "EDITORIAL_CHANGED_OR_NOT_READY"):
                return "La ficha ya no coincide con el episodio READY o salió de Listas (409). Original conservado."
            case .http(409), .decisionHTTP(409, _):
                return "La ficha, revisión o imagen ha cambiado (409). Actualiza la bandeja; original conservado."
            case .decisionHTTP(503, "EDITORIAL_SOURCE_UNAVAILABLE"):
                return "503: el servicio no pudo verificar la fuente editorial. No demuestra que la ficha haya salido de Listas; original conservado."
            case .decisionHTTP(503, "SOURCE_VERIFICATION_NOT_CONFIGURED"):
                return "503: verificación editorial sin configurar en el servicio privado. Original conservado."
            case .decisionHTTP(503, "STORAGE_NOT_CONFIGURED"):
                return "503: el almacenamiento privado no está configurado. Original conservado."
            case .decisionHTTP(503, "ORIGINAL_NOT_FOUND"):
                return "503: el publicador no encuentra el original. Se conserva la ficha para revisión."
            case .decisionHTTP(503, "TEMPORARILY_UNAVAILABLE"):
                return "503: fallo interno temporal del servicio privado. Conserva el original y no generes otro."
            case .decisionHTTP(let status, let code):
                // Only show short diagnostic error symbols, never raw server data.
                if let code, code.range(of: "^[A-Z][A-Z0-9_]{2,60}$",
                                        options: .regularExpression) != nil {
                    return "El servidor devolvió \(status) (\(code)). La decisión no está confirmada."
                }
                return "El servidor devolvió \(status). La decisión no está confirmada."
            case .http(let status): return "El servidor devolvió \(status)."
            case .unexpectedResponse: return "La confirmación del servidor no es válida."
            }
        }
    }
}

struct ImageApprovalInbox: View {
    @ObservedObject var github: GitHubEditor
    @EnvironmentObject private var store: EditorialStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ApprovalInboxModel.shared

    private func reload() async {
        await model.load(using: github)
    }

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
                        Text("Todas las imágenes originales pendientes recibidas, aunque la ficha ya no esté en el Top 30 o Listas. Aprobar siempre exige revalidar el episodio exacto en el servidor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !model.pageDiagnostics.isEmpty {
                            Text(model.pageDiagnostics)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
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
                                        model.decide(item, action: "approve", using: github)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                    Button("Rechazar") {
                                        model.decide(item, action: "reject", using: github)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                }
                                .disabled(model.processingIDs.contains(item.id) ||
                                          model.previews[item.id] == nil)
                            }
                            .padding(.vertical, 7)
                            .task(id: item.id) { await model.loadOriginal(item, using: github) }
                        }
                        if !model.loading && model.images.isEmpty && model.notice.isEmpty {
                            Text("No hay imágenes pendientes.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .refreshable { await reload() }
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
                    Button { Task { await reload() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!github.imageInboxConfigured || !github.authenticated || model.loading)
                    .accessibilityLabel("Actualizar imágenes pendientes")
                }
            }
            .task {
                if github.imageInboxConfigured && github.authenticated {
                    await reload()
                }
            }
        }
    }
}