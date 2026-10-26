import Foundation
import Combine
import Security
import UIKit

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

    private let repoURL = URL(string: "https://api.github.com/repos/fabricelop/europapress-rss/dispatches")!
    private let service = "com.fabricelop.ttactualidad.github"
    private var token: String = ""
    private var refreshToken: String = ""
    private var tokenExpires: Date = .distantPast
    private var deviceTask: Task<Void, Never>?

    init() { restoreSession() }

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
        guard id.hasPrefix("Iv") && id.count >= 12 && id.count <= 80 &&
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else {
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
                    do {
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
                        case "authorization_pending":
                            notice = "Esperando autorización en GitHub. Código: \(code)"
                        case "slow_down":
                            interval = max(interval + 5, (response["interval"] as? Int) ?? interval + 5)
                            notice = "GitHub solicita esperar más entre comprobaciones."
                        case "expired_token", "access_denied":
                            deviceCode = ""
                            throw GitHubError.message("El código caducó o se rechazó. Pulsa Conectar GitHub para obtener otro.")
                        default:
                            throw GitHubError.message(response["error_description"] as? String ??
                                "No se pudo autorizar GitHub.")
                        }
                    } catch {
                        if Task.isCancelled { return }
                        if Self.isTemporaryNetworkError(error) {
                            // A single temporary URLSession timeout must NOT stop the
                            // authorization listener while the GitHub code is valid.
                            notice = "Conexión lenta con GitHub. Se reintentará automáticamente; conserva el código \(code)."
                            continue
                        }
                        throw error
                    }
                }
                if !Task.isCancelled {
                    deviceCode = ""
                    notice = "El código caducó (15 minutos). Pulsa Conectar GitHub para obtener otro."
                }
            } catch {
                if !Task.isCancelled {
                    notice = Self.isTemporaryNetworkError(error)
                        ? "La conexión con GitHub agotó el tiempo. Comprueba la red y pulsa Conectar GitHub para reintentar."
                        : error.localizedDescription
                }
            }
        }
    }

    private static func isTemporaryNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
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

    // HTTP 204 is only a transport acknowledgement. Verify the committed state.
    private func readMainJSON(_ path: String) async throws -> [String: Any] {
        var url = URLComponents(string: "https://api.github.com/repos/fabricelop/europapress-rss/contents/" + path)!
        url.queryItems = [URLQueryItem(name: "ref", value: "main")]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + (try await authorizedToken()), forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GitHubError.message("No se pudo leer la confirmación de GitHub.")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GitHubError.message("Confirmación de GitHub malformada.")
        }
        return object
    }

    private func actionReceipt(_ requestID: String) async throws -> String? {
        let doc = try await readMainJSON("pilot/ttactualidad-action-receipts.json")
        let receipt = (doc["items"] as? [[String: Any]])?.first {
            ($0["request_id"] as? String) == requestID
        }
        return receipt?["status"] as? String
    }

    private func manualNewsPersisted(_ requestID: String) async throws -> Bool {
        let eventID = "manual-" + requestID
        for path in ["ttittulares/editorial-queue.json",
                     "telegram/editorial-processing.json", "ttittulares/prepared.json"] {
            let doc = try await readMainJSON(path)
            let rows = doc["items"] as? [[String: Any]] ?? []
            if rows.contains(where: { ($0["event_id"] as? String) == eventID }) { return true }
        }
        return false
    }

    private func confirmPersistence(event: String, requestID: String, label: String) async -> Bool {
        notice = "GitHub recibió «\(label)»; verificando el estado persistido…"
        // Slow GitHub Actions start is not treated as success or failure.
        for attempt in 0..<22 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(4)) }
            do {
                if event == "ttactualidad_manual_news_v1" {
                    if try await manualNewsPersisted(requestID) {
                        notice = "Verificado en GitHub: noticia añadida a En elaboración."
                        return true
                    }
                } else if event == "ttactualidad_batch_v1" {
                    let doc = try await readMainJSON("pilot/ttactualidad-batch-receipts.json")
                    let receipt = (doc["items"] as? [[String: Any]])?.first {
                        ($0["request_id"] as? String) == requestID
                    }
                    if let status = receipt?["status"] as? String {
                        if status == "applied" {
                            notice = "Lote verificado: todos los elementos persistidos en GitHub."
                            return true
                        }
                        notice = "Lote registrado con estado \(status)."
                        return false
                    }
                } else if let status = try await actionReceipt(requestID) {
                    if ["applied", "already_applied"].contains(status) {
                        notice = "Verificado en GitHub: «\(label)» aplicado."
                        return true
                    }
                    notice = "GitHub registró «\(label)»: \(status). Revisa el resultado."
                    return false
                }
            } catch {
                // Transient API errors are retried; no artificial success.
            }
        }
        notice = "Orden aceptada, pero aún sin confirmación de persistencia. Revisa Actions con el identificador \(requestID)."
        return false
    }

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
            guard let requestID = payload["request_id"] as? String else {
                notice = "Falta identificador para verificar la escritura."
                return false
            }
            let persisted = await confirmPersistence(event: event, requestID: requestID, label: label)
            if persisted { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            return persisted
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
        return await dispatch("ttactualidad_action_v1", payload: [
            "project": project, "event_id": eventID, "revision": revision,
            "decision": decision, "request_id": UUID().uuidString.lowercased(),
            "received_at": ISO8601DateFormatter().string(from: Date()),
            "trend_name": title, "trend_rank": rank
        ], label: decision == "deleted" ? "Quitar de Listas" : "Reelaborar / preparar")
    }

    // Batch operations carry the original ID and expected revision of every item.
    // GitHub applies them atomically and records one verifiable group receipt.
    func batch(project: String, decision: String,
               items: [[String: Any]], groupTopic: String = "") async -> Bool {
        guard (2...12).contains(items.count) else {
            notice = "Selecciona de 2 a 12 elementos."
            return false
        }
        if decision == "rework" && groupTopic.trimmingCharacters(in: .whitespacesAndNewlines).count < 4 {
            notice = "Indica un tema común para la reelaboración conjunta."
            return false
        }
        return await dispatch("ttactualidad_batch_v1", payload: [
            "project": project, "decision": decision,
            "request_id": UUID().uuidString.lowercased(),
            "items": items, "group_topic": String(groupTopic.prefix(160))
        ], label: decision == "rework" ? "Reelaborar tendencias relacionadas" : "Acción múltiple")
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
