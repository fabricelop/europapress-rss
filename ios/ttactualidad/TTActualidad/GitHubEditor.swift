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
    // Each async dispatch returns its own result; concurrent requests cannot
    // accidentally exchange another action's verification status.
    private var inFlightKeys = Set<String>()

    enum WriteResult: Equatable {
        case verified
        case pending
        case failed
    }

    private let repoURL = URL(string: "https://api.github.com/repos/fabricelop/europapress-rss/dispatches")!
    private let service = "com.fabricelop.ttactualidad.github"
    private var token: String = ""
    private var refreshToken: String = ""
    private var tokenExpires: Date = .distantPast
    private var refreshTokenExpires: Date = .distantFuture
    private var refreshTask: Task<String, Error>?
    private var deviceTask: Task<Void, Never>?

    private struct SecureSession: Codable {
        let accessToken: String
        let refreshToken: String
        let accessExpiresAt: Double
        let refreshExpiresAt: Double
    }

    var sessionSummary: String {
        guard authenticated else { return "No hay una autorización activa." }
        if refreshToken.isEmpty {
            return "Acceso guardado en el llavero del iPhone. Sin renovación periódica requerida."
        }
        if refreshTokenExpires == .distantFuture {
            return "Renovación automática activa. No es necesario vincular GitHub cada día."
        }
        return "Renovación automática activa. Credencial renovable hasta " +
            refreshTokenExpires.formatted(date: .abbreviated, time: .omitted) + "."
    }

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

    // Update existing Keychain records instead of delete-then-add; a failed
    // write must not destroy the previous rotating refresh token.
    @discardableResult
    private func save(_ key: String, value: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        if value.isEmpty { return SecItemDelete(query as CFDictionary) == errSecSuccess ||
                                  credential(key).isEmpty }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var insertion = query
        insertion.merge(attributes, uniquingKeysWith: { _, new in new })
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }

    private func restoreSession() {
        let saved = credential("session")
        if let data = saved.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SecureSession.self, from: data) {
            token = decoded.accessToken
            refreshToken = decoded.refreshToken
            tokenExpires = Date(timeIntervalSince1970: decoded.accessExpiresAt)
            refreshTokenExpires = Date(timeIntervalSince1970: decoded.refreshExpiresAt)
        } else {
            // Migrate v0.3.x installations without requiring another login.
            token = credential("access")
            refreshToken = credential("refresh")
            if let expiry = TimeInterval(credential("expires")), expiry > 0 {
                tokenExpires = Date(timeIntervalSince1970: expiry)
            } else {
                // A non-expiring GitHub App token has no expires_in field.
                tokenExpires = !token.isEmpty && refreshToken.isEmpty ?
                    .distantFuture : .distantPast
            }
            if !token.isEmpty || !refreshToken.isEmpty { try? persistSession() }
        }
        authenticated = !token.isEmpty || !refreshToken.isEmpty
        if authenticated { notice = "GitHub vinculado · renovación automática activada." }
    }

    private func persistSession() throws {
        let envelope = SecureSession(accessToken: token, refreshToken: refreshToken,
                                     accessExpiresAt: tokenExpires.timeIntervalSince1970,
                                     refreshExpiresAt: refreshTokenExpires.timeIntervalSince1970)
        let json = try JSONEncoder().encode(envelope)
        guard let string = String(data: json, encoding: .utf8),
              save("session", value: string) else {
            throw GitHubError.message("El iPhone no pudo guardar la sesión en el llavero seguro.")
        }
    }

    func logout() {
        deviceTask?.cancel()
        refreshTask?.cancel()
        for key in ["session", "access", "refresh", "expires"] { save(key, value: "") }
        token = ""; refreshToken = ""; tokenExpires = .distantPast
        refreshTokenExpires = .distantFuture
        authenticated = false; deviceCode = ""
        notice = "Sesión GitHub desconectada."
    }

    // Do not mark the account disconnected because of an offline start,
    // temporary GitHub error or failed background refresh.
    func renewOnForeground() async {
        guard authenticated else { return }
        if !token.isEmpty && tokenExpires > Date().addingTimeInterval(60 * 60) { return }
        do {
            _ = try await authorizedToken()
            notice = "GitHub conectado · sesión renovada automáticamente."
        } catch {
            if authenticated {
                notice = "GitHub vinculado; renovación pendiente de conexión. " +
                    error.localizedDescription
            }
        }
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
                            try acceptTokens(response, access: access)
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

    private func acceptTokens(_ response: [String: Any], access: String) throws {
        // The new refresh token invalidates the old one. Persist both as one
        // Keychain record BEFORE reporting that authentication has succeeded.
        let newRefresh = response["refresh_token"] as? String ?? refreshToken
        let expires: Date = (response["expires_in"] as? Int).map {
            Date().addingTimeInterval(TimeInterval($0))
        } ?? .distantFuture
        let refreshExpires: Date = (response["refresh_token_expires_in"] as? Int).map {
            Date().addingTimeInterval(TimeInterval($0))
        } ?? refreshTokenExpires
        let envelope = SecureSession(accessToken: access, refreshToken: newRefresh,
                                     accessExpiresAt: expires.timeIntervalSince1970,
                                     refreshExpiresAt: refreshExpires.timeIntervalSince1970)
        let json = try JSONEncoder().encode(envelope)
        guard let saved = String(data: json, encoding: .utf8),
              save("session", value: saved) else {
            throw GitHubError.message("Autorizado, pero el llavero del iPhone no pudo guardar la sesión.")
        }
        token = access
        refreshToken = newRefresh
        tokenExpires = expires
        refreshTokenExpires = refreshExpires
        authenticated = true
        // New installations use the atomic record; remove fragile legacy keys.
        for key in ["access", "refresh", "expires"] { save(key, value: "") }
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
        if !token.isEmpty && tokenExpires > Date().addingTimeInterval(90) {
            return token
        }
        if let refreshTask { return try await refreshTask.value }
        guard !refreshToken.isEmpty, !clientID.isEmpty else {
            // Non-expiring access tokens have no refresh token.
            if !token.isEmpty && tokenExpires == .distantFuture { return token }
            authenticated = false
            throw GitHubError.message("Esta autorización de GitHub ya no tiene credenciales renovables.")
        }
        guard Date() < refreshTokenExpires else {
            authenticated = false
            throw GitHubError.message("El token de renovación ha caducado; vincula GitHub otra vez.")
        }

        // All simultaneous editorial writes share this exact rotation.
        let task = Task<String, Error> {
            let response = try await githubForm(
                "https://github.com/login/oauth/access_token",
                parameters: ["client_id": clientID, "refresh_token": refreshToken,
                             "grant_type": "refresh_token"])
            if let access = response["access_token"] as? String {
                try acceptTokens(response, access: access)
                return access
            }
            let code = response["error"] as? String ?? ""
            if code == "bad_refresh_token" {
                authenticated = false
                throw GitHubError.message("GitHub ha invalidado la renovación. Es necesario volver a vincular.")
            }
            // Other GitHub errors do not revoke a valid stored session.
            throw GitHubError.message(response["error_description"] as? String ??
                                      "Renovación temporalmente no disponible.")
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
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
        // The workflow atomically commits this queue: one fast read for confirmation.
        let queue = try await readMainJSON("ttittulares/editorial-queue.json")
        let rows = queue["items"] as? [[String: Any]] ?? []
        if rows.contains(where: { ($0["event_id"] as? String) == eventID }) { return true }
        // A fast editorial processor can move the entry to a completed state.
        let prepared = try await readMainJSON("ttittulares/prepared.json")
        return (prepared["items"] as? [[String: Any]] ?? []).contains {
            ($0["event_id"] as? String) == eventID
        }
    }

    private func confirmPersistence(event: String, requestID: String, label: String) async -> Bool {
        notice = "GitHub recibió «\(label)»; verificando el estado persistido…"
        // Slow GitHub Actions start is not treated as success or failure.
        for attempt in 0..<32 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
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

    func dispatch(_ event: String, payload: [String: Any], label: String) async -> WriteResult {
        guard authenticated else {
            notice = "Conecta primero tu GitHub App en Ajustes."
            return .failed
        }
        let project = payload["project"] as? String ?? event
        let identifier = payload["event_id"] as? String ??
                         payload["request_id"] as? String ?? event
        let key = project + ":" + identifier
        guard !inFlightKeys.contains(key) else {
            notice = "Esta orden ya está en curso; no es necesario enviarla otra vez."
            return .pending
        }
        inFlightKeys.insert(key)
        activeAction = label
        defer {
            inFlightKeys.remove(key)
            if inFlightKeys.isEmpty { activeAction = nil }
        }
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
                return .failed
            }
            let persisted = await confirmPersistence(event: event, requestID: requestID, label: label)
            if persisted { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            return persisted ? .verified : .pending
        } catch {
            let asURL = error as? URLError
            // A POST timeout has indeterminate outcome. Do not undo its
            // optimistic state unless GitHub explicitly rejected the write.
            if asURL?.code == .timedOut || asURL?.code == .networkConnectionLost {
                notice = "La red interrumpió la confirmación. La orden puede estar procesándose en GitHub."
            } else {
                notice = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            return (asURL?.code == .timedOut || asURL?.code == .networkConnectionLost) ? .pending : .failed
        }
    }

    // Request the REAL existing editorial runners, not a GitHub Actions build.
    // Both PC/Work listeners watch dedicated control branches for committed
    // run-now-trigger.json changes. A confirmed write is NOT editorial DONE.
    func requestEditorialRun(project: String) async -> WriteResult {
        guard ["ttittulares", "ttendencias"].contains(project) else {
            notice = "Proyecto editorial no reconocido."
            return .failed
        }
        guard authenticated else {
            notice = "Conecta la cuenta GitHub antes de solicitar una pasada."
            return .failed
        }
        let key = "run-editorial:" + project
        guard !inFlightKeys.contains(key) else {
            notice = "Ya se está registrando una solicitud para " + project + "."
            return .pending
        }
        inFlightKeys.insert(key)
        activeAction = "Procesar " + project
        defer {
            inFlightKeys.remove(key)
            if inFlightKeys.isEmpty { activeAction = nil }
        }
        do {
            let access = try await authorizedToken()
            var branch = "control/ttendencias-run-trigger"
            var filename = "trends/run-now-trigger.json"
            if project == "ttittulares" {
                // The permanent PR #2 is the live listener target. Older
                // control/ttittulares-run-trigger is NOT the PR head anymore.
                let prURL = URL(string:
                    "https://api.github.com/repos/fabricelop/europapress-rss/pulls/2")!
                var prRequest = URLRequest(url: prURL, timeoutInterval: 20)
                prRequest.setValue("Bearer " + access,
                                   forHTTPHeaderField: "Authorization")
                let (prData, prResponse) = try await URLSession.shared.data(for: prRequest)
                guard (prResponse as? HTTPURLResponse)?.statusCode == 200,
                      let pr = (try JSONSerialization.jsonObject(with: prData)) as? [String: Any],
                      let head = pr["head"] as? [String: Any],
                      let headName = head["ref"] as? String,
                      headName.hasPrefix("control/ttittulares-run-trigger"),
                      let headRepo = head["repo"] as? [String: Any],
                      (headRepo["full_name"] as? String) == "fabricelop/europapress-rss",
                      (pr["state"] as? String) == "open" else {
                    throw GitHubError.message("No se puede verificar la rama activa del PR #2.")
                }
                branch = headName
                filename = "ttittulares/run-now-trigger.json"
            }
            var components = URLComponents(string:
                "https://api.github.com/repos/fabricelop/europapress-rss/contents/" + filename)!
            components.queryItems = [URLQueryItem(name: "ref", value: branch)]
            let apiURL = components.url!
            var getRequest = URLRequest(url: apiURL, timeoutInterval: 20)
            getRequest.setValue("Bearer " + access,
                                forHTTPHeaderField: "Authorization")
            getRequest.setValue("application/vnd.github+json",
                                forHTTPHeaderField: "Accept")
            let (existing, getResponse) = try await URLSession.shared.data(for: getRequest)
            guard (getResponse as? HTTPURLResponse)?.statusCode == 200,
                  let file = (try JSONSerialization.jsonObject(with: existing)) as? [String: Any],
                  let fileSHA = file["sha"] as? String,
                  let base64 = file["content"] as? String else {
                throw GitHubError.message("No se encuentra el disparador editorial vigente.")
            }
            // Deduplicate manual taps close to an existing manual/auto request.
            if let raw = Data(base64Encoded: base64.filter { !$0.isWhitespace }),
               let old = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
               let previous = old["requested_at"] as? String,
               let timestamp = ISO8601DateFormatter().date(from: previous),
               Date().timeIntervalSince(timestamp) >= 0,
               Date().timeIntervalSince(timestamp) < 90 {
                notice = "Ya hay una pasada reciente solicitada. No se ha duplicado."
                return .verified
            }
            let moment = Date()
            let prefix = project == "ttittulares" ? "tt" : "tr"
            let commandID = prefix + "-ios-" +
                String(Int(moment.timeIntervalSince1970 * 1000)) + "-" +
                String(UUID().uuidString.prefix(8)).lowercased()
            let payload: [String: Any] = [
                "version": 2, "command_id": commandID,
                "requested_at": ISO8601DateFormatter().string(from: moment),
                "mode": "manual_pc_chat",
                "executor": project == "ttittulares" ?
                    "pc_chat_ttittulares_dedicated" : "pc_chat_ttendencias_dedicated",
                "project": project,
                "launcher_arg": project == "ttittulares" ? "titulares" : "tendencias",
                "task": "editorial", "auto_image_followup": false,
                "source": "ttactualidad_ios"
            ]
            let document = try JSONSerialization.data(withJSONObject: payload,
                                                       options: [.prettyPrinted, .sortedKeys])
            let body: [String: Any] = [
                "branch": branch, "sha": fileSHA,
                "message": "TTActualidad: solicitar pasada editorial " + commandID,
                "content": document.base64EncodedString()
            ]
            var putRequest = URLRequest(url: URL(string:
                "https://api.github.com/repos/fabricelop/europapress-rss/contents/" + filename)!,
                                        timeoutInterval: 25)
            putRequest.httpMethod = "PUT"
            putRequest.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            putRequest.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            putRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            putRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (written, response) = try await URLSession.shared.data(for: putRequest)
            guard [200, 201].contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                  let result = (try JSONSerialization.jsonObject(with: written)) as? [String: Any],
                  let commit = result["commit"] as? [String: Any],
                  (commit["sha"] as? String)?.isEmpty == false else {
                throw GitHubError.message("GitHub no confirmó el disparador. Comprueba el PR y reintenta.")
            }
            notice = "Solicitud " + commandID +
                     " confirmada en GitHub. El procesador debe recogerla; aún no significa DONE."
            return .verified
        } catch {
            notice = error.localizedDescription
            return .failed
        }
    }

    func decide(project: String, eventID: String, revision: Int, decision: String,
                title: String, rank: Int = 0,
                requestID: String = UUID().uuidString.lowercased()) async -> WriteResult {
        guard !eventID.isEmpty, revision >= 0 else {
            notice = "La entrada no tiene identificador editorial confirmado. Actualiza primero."
            return .failed
        }
        return await dispatch("ttactualidad_action_v1", payload: [
            "project": project, "event_id": eventID, "revision": revision,
            "decision": decision, "request_id": requestID,
            "received_at": ISO8601DateFormatter().string(from: Date()),
            "trend_name": title, "trend_rank": rank
        ], label: decision == "published" ? "Publicado · quitar de Listas" :
                  decision == "deleted" ? "No publicado · quitar de Listas" :
                  "Reelaborar / preparar")
    }

    // Uses the existing direct action + exact GitHub receipt; never a second queue.
    // The editor's information is unverified until investigated independently.
    func submitTrendHints(eventID: String, revision: Int, title: String,
                          rank: Int, hints: String, requestID: String) async -> WriteResult {
        let text = hints.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 && text.count <= 6000,
              !eventID.isEmpty && revision >= 0 else {
            notice = "Escribe entre 8 y 6000 caracteres de pistas y comprueba la tendencia."
            return .failed
        }
        return await dispatch("ttactualidad_action_v1", payload: [
            "project": "ttendencias", "event_id": eventID, "revision": revision,
            "decision": "hints", "request_id": requestID,
            "received_at": ISO8601DateFormatter().string(from: Date()),
            "trend_name": title, "trend_rank": rank,
            "hints": text
        ], label: "Aportar pistas · nueva investigación")
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
        ], label: decision == "rework" ? "Reelaborar tendencias relacionadas" : "Acción múltiple") == .verified
    }

    func groupListas(requestID: String, removeCovered: [TrendItem]? = nil) async -> WriteResult {
        var payload: [String: Any] = [
            "project": "ttendencias", "event_id": "listas-grouping",
            "request_id": requestID,
            "decision": removeCovered == nil ? "group_listas" : "remove_covered"
        ]
        if let items = removeCovered {
            payload["items"] = items.map { ["id": $0.editorialID, "revision": $0.revision] as [String: Any] }
        }
        return await dispatch("ttactualidad_group_listas_v1", payload: payload,
                              label: removeCovered == nil ? "Agrupar Listas" : "Retirar agrupadas")
    }

    func addNews(title: String, url: String, instructions: String,
                 requestID: String? = nil,
                 originTrend: TrendItem? = nil) async -> WriteResult {
        guard !title.isEmpty || !url.isEmpty else { notice = "Añade un enlace o una descripción."; return .failed }
        if !title.isEmpty && title.count < 5 { notice = "La descripción debe tener al menos 5 caracteres."; return .failed }
        if !url.isEmpty {
            guard let address = URL(string: url), address.scheme == "https", address.host != nil else {
                notice = "El enlace debe empezar por https://"; return .failed
            }
        }
        var payload: [String: Any] = [
            "project": "ttittulares", "request_id": requestID ?? UUID().uuidString.lowercased(),
            "title": String(title.prefix(240)), "url": String(url.prefix(2000)),
            "instructions": String(instructions.prefix(1000))
        ]
        if let origin = originTrend {
            payload["origin_trend"] = [
                "id": origin.editorialID, "revision": origin.revision,
                "name": origin.name
            ]
        }
        return await dispatch("ttactualidad_manual_news_v1", payload: payload,
                              label: originTrend == nil ? "Añadir noticia" :
                                     "Enviar tendencia a TTiTTulares")
    }
}

