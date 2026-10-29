import Foundation
import Combine
import Security
import UIKit

// A bounded receipt tracker confirms server results instead of leaving accepted
// requests visible as "pending" indefinitely.
struct EditorialReceiptPending: Codable, Identifiable {
    let requestID: String
    let project: String
    let eventID: String
    let revision: Int
    let decision: String
    let title: String
    let sentAt: Date
    var id: String { requestID }
}

// Direct GitHub App user authorization. No embedded secret, personal token prompt,
// Cloudflare Worker or broad GitHub OAuth "repo" scope.
@MainActor
final class GitHubEditor: ObservableObject {
    @Published private(set) var authenticated = false
    @Published var clientID = UserDefaults.standard.string(forKey: "TTActualidad.githubAppClientID") ?? ""
    @Published private(set) var deviceCode = ""
    @Published private(set) var isConnecting = false
    @Published private(set) var notice = "Conecta GitHub una vez para activar las acciones editoriales."
    @Published private(set) var activeAction: String? = nil
    @Published private(set) var pendingReceipts: [EditorialReceiptPending] = []
    @Published private(set) var receiptChange = 0
    // Immediate visual closure; GitHub receipts, not HTTP 204, determine success.
    @Published private(set) var optimisticClosures = Set<String>()

    private let repoURL = URL(string: "https://api.github.com/repos/fabricelop/europapress-rss/dispatches")!
    private let service = "com.fabricelop.ttactualidad.github"
    private var token: String = ""
    private var refreshToken: String = ""
    private var tokenExpires: Date = .distantPast
    private var deviceTask: Task<Void, Never>?
    private let pendingKey = "TTActualidad.pendingEditorialReceipts.v1"
    private var receiptPolling = Set<String>()
    private var receiptReadInProgress = false

    init() {
        restoreSession()
        if let saved = UserDefaults.standard.data(forKey: pendingKey),
           let entries = try? JSONDecoder().decode([EditorialReceiptPending].self, from: saved) {
            pendingReceipts = entries
            optimisticClosures = Set(entries.filter { ["published", "deleted"].contains($0.decision) }
                .map { Self.closureKey(project: $0.project, eventID: $0.eventID, revision: $0.revision) })
        }
        Task { await resumeReceiptChecks() }
    }

    private func credential(_ key: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    private func save(_ key: String, value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    private func restoreSession() {
        token = credential("access")
        refreshToken = credential("refresh")
        tokenExpires = Date(timeIntervalSince1970: TimeInterval(credential("expires")) ?? 0)
        authenticated = !token.isEmpty || !refreshToken.isEmpty
        if authenticated { notice = "Cuenta GitHub vinculada al iPhone." }
    }

    func logout() {
        deviceTask?.cancel()
        for key in ["access", "refresh", "expires"] { save(key, value: "") }
        token = ""; refreshToken = ""; tokenExpires = .distantPast
        authenticated = false; deviceCode = ""
        notice = "Sesión GitHub desconectada."
    }

    func beginLogin() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasPrefix("Iv1.") || id.hasPrefix("Ov23li.") else {
            notice = "Introduce el Client ID de la GitHub App (no es un token secreto)."
            return
        }
        UserDefaults.standard.set(id, forKey: "TTActualidad.githubAppClientID")
        deviceTask?.cancel()
        deviceTask = Task {
            isConnecting = true
            defer { isConnecting = false }
            do {
                let result = try await githubForm(
                    "https://github.com/login/device/code", parameters: ["client_id": id])
                guard let code = result["user_code"] as? String,
                      let secret = result["device_code"] as? String else {
                    throw GitHubError.message(result["error_description"] as? String ?? "No llegó el código de vinculación.")
                }
                deviceCode = code
                UIPasteboard.general.string = code
                notice = "Código copiado. Autorízalo en github.com/login/device."
                let duration = (result["expires_in"] as? Int) ?? 900
                var interval = max(5, (result["interval"] as? Int) ?? 5)
                let deadline = Date().addingTimeInterval(TimeInterval(duration))
                while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    let response = try await githubForm(
                        "https://github.com/login/oauth/access_token",
                        parameters: ["client_id": id, "device_code": secret,
                                     "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
                    if let access = response["access_token"] as? String {
                        acceptTokens(response, access: access)
                        deviceCode = ""
                        notice = "GitHub conectado. Ya puedes enviar órdenes editoriales."
                        return
                    }
                    switch response["error"] as? String ?? "" {
                    case "authorization_pending": break
                    case "slow_down": interval = max(interval + 5, (response["interval"] as? Int) ?? interval + 5)
                    default: throw GitHubError.message(response["error_description"] as? String ?? "No se pudo autorizar GitHub.")
                    }
                }
                if !Task.isCancelled { notice = "Código caducado. Vuelve a conectar GitHub." }
            } catch {
                if !Task.isCancelled { notice = error.localizedDescription }
            }
        }
    }

    private func acceptTokens(_ response: [String: Any], access: String) {
        token = access
        if let refreshed = response["refresh_token"] as? String { refreshToken = refreshed }
        let expires = response["expires_in"] as? Int ?? (7 * 3600)
        tokenExpires = Date().addingTimeInterval(TimeInterval(expires))
        save("access", value: token)
        save("refresh", value: refreshToken)
        save("expires", value: String(tokenExpires.timeIntervalSince1970))
        authenticated = true
    }

    private func githubForm(_ endpoint: String, parameters: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: endpoint) else { throw GitHubError.message("URL incorrecta") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = parameters.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GitHubError.message("GitHub no pudo completar la autorización.")
        }
        return object
    }

    private func authorizedToken() async throws -> String {
        if tokenExpires > Date().addingTimeInterval(90) && !token.isEmpty { return token }
        guard !refreshToken.isEmpty, !clientID.isEmpty else {
            authenticated = false
            throw GitHubError.message("Vuelve a conectar GitHub para editar.")
        }
        let response = try await githubForm(
            "https://github.com/login/oauth/access_token",
            parameters: ["client_id": clientID, "refresh_token": refreshToken,
                         "grant_type": "refresh_token"])
        guard let access = response["access_token"] as? String else {
            authenticated = false
            throw GitHubError.message("La sesión caducó. Reconecta GitHub.")
        }
        acceptTokens(response, access: access)
        return access
    }

    enum GitHubError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let value) = self { return value }
            return "Error GitHub"
        }
    }

    // 204 means "accepted by GitHub", NOT "the editorial action has been persisted".
    func dispatch(_ event: String, payload: [String: Any], label: String) async -> Bool {
        guard authenticated else {
            notice = "Conecta primero tu GitHub App en Ajustes."
            return false
        }
        guard activeAction == nil else { notice = "Hay otra orden en curso."; return false }
        activeAction = label
        defer { activeAction = nil }
        do {
            let access = try await authorizedToken()
            var request = URLRequest(url: repoURL, timeoutInterval: 25)
            request.httpMethod = "POST"
            request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "event_type": event, "client_payload": payload])
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 204 else {
                let description = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                throw GitHubError.message("GitHub rechazó la orden (\(status)): " +
                                          String(describing: description?["message"] ?? "Comprueba permisos Contents: escritura e instalación de la App."))
            }
            notice = "GitHub aceptó «\(label)». Falta confirmar su aplicación editorial."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return true
        } catch {
            notice = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    func decide(project: String, eventID: String, revision: Int, decision: String,
                title: String, rank: Int = 0) async -> Bool {
        guard !eventID.isEmpty, revision >= 0 else {
            notice = "La entrada no tiene identificador editorial confirmado. Actualiza primero."
            return false
        }
        let requestID = UUID().uuidString.lowercased()
        let label = decision == "deleted" ? "Quitar de Listas" :
                    decision == "published" ? "Marcar publicada" : "Reelaborar / preparar"
        let accepted = await dispatch("ttactualidad_action_v1", payload: [
            "project": project, "event_id": eventID, "revision": revision,
            "decision": decision, "request_id": requestID,
            "received_at": ISO8601DateFormatter().string(from: Date()),
            "trend_name": title, "trend_rank": rank
        ], label: label)
        if accepted {
            let entry = EditorialReceiptPending(requestID: requestID, project: project,
                eventID: eventID, revision: revision, decision: decision,
                title: title, sentAt: Date())
            pendingReceipts.append(entry)
            if ["published", "deleted"].contains(decision) {
                optimisticClosures.insert(Self.closureKey(project: project, eventID: eventID, revision: revision))
            }
            persistPendingReceipts()
            Task { await followReceipt(requestID) }
        }
        return accepted
    }

    private static func closureKey(project: String, eventID: String, revision: Int) -> String {
        "\(project):\(eventID):r\(revision)"
    }

    func isOptimisticallyHidden(project: String, eventID: String, revision: Int) -> Bool {
        optimisticClosures.contains(Self.closureKey(project: project, eventID: eventID, revision: revision))
    }

    // Keep a confirmed closure hidden across a stale GitHub read. Remove its
    // overlay only once the canonical Listas snapshot no longer contains it.
    func reconcileOptimisticClosures(news: [NewsItem], trends: [TrendItem]) {
        let visible = Set(news.map { Self.closureKey(project: "ttittulares", eventID: $0.id, revision: $0.revision) }
            + trends.map { Self.closureKey(project: "ttendencias", eventID: $0.editorialID, revision: $0.revision) })
        let pending = Set(pendingReceipts.filter { ["published", "deleted"].contains($0.decision) }
            .map { Self.closureKey(project: $0.project, eventID: $0.eventID, revision: $0.revision) })
        optimisticClosures.formIntersection(visible.union(pending))
    }

    private func persistPendingReceipts() {
        if let data = try? JSONEncoder().encode(pendingReceipts) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }

    func resumeReceiptChecks() async {
        for pending in pendingReceipts {
            if !receiptPolling.contains(pending.requestID) {
                Task { await followReceipt(pending.requestID) }
            }
        }
    }

    // Called on app launch and return to foreground. No permanent spinner or
    // indefinite "orden por confirmar": each accepted request has a bounded
    // check, with a precise result or explicit unverified outcome.
    private func followReceipt(_ requestID: String) async {
        guard receiptPolling.insert(requestID).inserted else { return }
        defer { receiptPolling.remove(requestID) }
        for attempt in 0..<26 {
            guard pendingReceipts.contains(where: { $0.requestID == requestID }) else { return }
            await checkPendingReceipts()
            guard pendingReceipts.contains(where: { $0.requestID == requestID }) else { return }
            if attempt < 25 {
                try? await Task.sleep(for: .seconds(5))
            }
        }
        expireUnverifiedReceipts()
    }

    private func expireUnverifiedReceipts() {
        let now = Date()
        let expired = pendingReceipts.filter { now.timeIntervalSince($0.sentAt) > 120 }
        guard !expired.isEmpty else { return }
        let names = expired.map { $0.title }.joined(separator: ", ")
        for entry in expired {
            optimisticClosures.remove(Self.closureKey(project: entry.project, eventID: entry.eventID, revision: entry.revision))
        }
        pendingReceipts.removeAll { now.timeIntervalSince($0.sentAt) > 110 }
        persistPendingReceipts()
        notice = "Sin comprobante de GitHub para: \(names). No se ha declarado éxito; comprueba Acciones."
        receiptChange += 1
    }

    func checkPendingReceipts() async {
        guard !receiptReadInProgress, !pendingReceipts.isEmpty else { return }
        receiptReadInProgress = true
        defer { receiptReadInProgress = false }
        var url = URLComponents(string:
            "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/pilot/ttactualidad-action-receipts.json")!
        url.queryItems = [URLQueryItem(name: "check", value: UUID().uuidString)]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return }
            var settled = Set<String>()
            var failed = Set<String>()
            var message = ""
            for pending in pendingReceipts {
                guard let receipt = items.last(where: {
                    ($0["request_id"] as? String) == pending.requestID
                }) else { continue }
                // Never accept a receipt for a different item/revision/decision.
                guard (receipt["project"] as? String) == pending.project,
                      (receipt["event_id"] as? String) == pending.eventID,
                      (receipt["decision"] as? String) == pending.decision,
                      (receipt["revision"] as? Int) == pending.revision
                else { continue }
                let state = (receipt["status"] as? String) ?? ""
                settled.insert(pending.requestID)
                if ["applied", "already_applied"].contains(state) {
                    message = "GitHub confirmó «\(pending.title)» (\(pending.decision))."
                } else {
                    failed.insert(pending.requestID)
                    message = "GitHub no aplicó «\(pending.title)»: \(state)."
                }
            }
            if !settled.isEmpty {
                for entry in pendingReceipts where failed.contains(entry.requestID) {
                    optimisticClosures.remove(Self.closureKey(project: entry.project, eventID: entry.eventID, revision: entry.revision))
                }
                pendingReceipts.removeAll { settled.contains($0.requestID) }
                persistPendingReceipts()
                notice = message
                receiptChange += 1
            }
        } catch {
            // Network errors never imply that the editorial action succeeded.
        }
        expireUnverifiedReceipts()
    }

    func addNews(title: String, url: String, instructions: String) async -> Bool {
        guard !title.isEmpty || !url.isEmpty else { notice = "Añade un enlace o una descripción."; return false }
        if !title.isEmpty && title.count < 5 { notice = "La descripción debe tener al menos 5 caracteres."; return false }
        if !url.isEmpty {
            guard let address = URL(string: url), address.scheme == "https", address.host != nil else {
                notice = "El enlace debe empezar por https://"; return false
            }
        }
        return await dispatch("ttactualidad_manual_news_v1", payload: [
            "project": "ttittulares", "request_id": UUID().uuidString.lowercased(),
            "title": String(title.prefix(240)), "url": String(url.prefix(2000)),
            "instructions": String(instructions.prefix(1000))
        ], label: "Añadir noticia")
    }
}
