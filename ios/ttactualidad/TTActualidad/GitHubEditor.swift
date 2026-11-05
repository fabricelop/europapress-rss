import Foundation
import CryptoKit
import Combine
import Security
import UIKit

private final class EditorialRelationsNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
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

    // Immutable endpoint supplied at build time, never typed by an untrusted page.
    // The editor GitHub OAuth token is sent only to this explicitly configured HTTPS host.
    private var imageInboxBaseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TTImageApprovalAPIBaseURL") as? String,
              !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil,
              url.host == "ttactualidad.rainyraven22.chatgpt.site",
              url.path == "/api/image-inbox",
              url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }

    var imageInboxConfigured: Bool { imageInboxBaseURL != nil }

    // Only this immutable owner-private endpoint may receive the editor token.
    // No path, host, redirect target or credential is supplied by content/search.
    func privateEditorialRelationsRequest(path: String, method: String = "GET",
                                         jsonBody: Data? = nil) async throws -> (Data, Int) {
        guard (path == "/v1/snapshot" && method == "GET") ||
              (path == "/v1/decisions" && method == "POST"),
              let url = URL(string: "https://ttactualidad.rainyraven22.chatgpt.site/api/editorial-relations" + path)
        else { throw GitHubError.message("Ruta privada de relaciones no permitida.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer " + (try await authorizedToken()), forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("TTActualidad/0.4.56", forHTTPHeaderField: "User-Agent")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: EditorialRelationsNoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https",
              http.url?.host == "ttactualidad.rainyraven22.chatgpt.site",
              http.url?.path == url.path else {
            throw GitHubError.message("No hay respuesta privada verificable.")
        }
        return (bytes, http.statusCode)
    }

    func privateImageInboxRequest(path: String, method: String = "GET",
                                  jsonBody: Data? = nil) async throws -> (Data, Int) {
        guard let base = imageInboxBaseURL else {
            throw GitHubError.message("El servicio privado de imágenes no está configurado.")
        }
        guard path.range(of: "^/v1/images(?:/[a-f0-9]{64}/(?:original|decision))?$",
                         options: .regularExpression) != nil,
              ["GET", "POST"].contains(method),
              let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)
        else { throw GitHubError.message("Ruta privada no permitida.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 25)
        request.httpMethod = method
        request.setValue("Bearer " + (try await authorizedToken()), forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("TTActualidad/0.4.50", forHTTPHeaderField: "User-Agent")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.message("No hay respuesta HTTP verificable.")
        }
        return (bytes, http.statusCode)
    }

    // Manual upload is never a public image publication. It adds a verified PNG
    // to the existing private approval inbox, which remains the only publisher.
    func uploadEditorialImage(
        project: String, editorialID: String, revision: Int, title: String,
        editorialText: String, png: Data, commandID: String
    ) async throws -> (Data, Int) {
        guard let base = imageInboxBaseURL,
              ["ttittulares", "ttendencias"].contains(project),
              !editorialID.isEmpty, revision >= 0,
              png.count >= 24, png.count <= 8_000_000
        else { throw GitHubError.message("Servicio privado o identidad editorial no válida.") }
        let digest = SHA256.hash(data: png)
            .map { String(format: "%02x", $0) }.joined()
        let metadata: [String: Any] = [
            "project": project, "editorialId": editorialID, "revision": revision,
            "title": title, "editorialText": editorialText,
            "commandId": commandID, "rasterSHA256": digest,
        ]
        let payload = try JSONSerialization.data(withJSONObject: metadata)
        guard let url = URL(string: base.absoluteString + "/v1/images/manual"),
              url.scheme == "https",
              url.host == "ttactualidad.rainyraven22.chatgpt.site" else {
            throw GitHubError.message("Destino privado no permitido.")
        }
        let boundary = "TTActualidadManual-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"metadata\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(payload)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"original.png\"\r\n")
        append("Content-Type: image/png\r\n\r\n")
        body.append(png)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer " + (try await authorizedToken()), forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("TTActualidad/iOS-manual-image", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral,
                                 delegate: EditorialRelationsNoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == url.host,
              http.url?.path == url.path else {
            throw GitHubError.message("Respuesta privada no verificable.")
        }
        return (bytes, http.statusCode)
    }

    // GitHub Contents fallback: used only if Sites has no manual upload endpoint.
    // The chosen image becomes a public, content-addressed original, but never
    // claims to be published on ChatGPT Sites until separate readback succeeds.
    func associateManualImageInGitHub(project: String, editorialID: String,
                                     revision: Int, editorialText: String,
                                     png: Data) async throws -> URL {
        guard ["ttendencias", "ttittulares"].contains(project),
              editorialID.range(of: "^[A-Za-z0-9_-]{3,160}$", options: .regularExpression) != nil,
              revision >= (project == "ttittulares" ? 1 : 0),
              !editorialText.isEmpty, png.count > 24, png.count <= 8_000_000
        else { throw GitHubError.message("Ficha o imagen incorrecta.") }
        let hex = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let folder = project == "ttendencias" ? "trends" : "ttittulares"
        let path = folder + "/generated-images/" + editorialID + "-r" + String(revision) +
            "-manual-" + String(hex.prefix(12)) + ".png"
        let originalURL = URL(string: "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/" + path)!
        let sourcePath = project == "ttendencias" ?
            "trends/telegram-manual-explained.json" : "ttittulares/prepared.json"
        // This is a historical image association, independent of Listas.
        // The editor must explicitly choose the image and an exact existing
        // ID/revision/text/date, but published/removed cards remain eligible.
        let manifestPath = folder + "/site-ai-images.json"
        let auth = try await authorizedToken()
        func currentRow() async throws -> [String: Any] {
            let data = try await readMainJSON(sourcePath)
            let matches = (data["items"] as? [[String: Any]] ?? []).filter {
                ($0[project == "ttendencias" ? "id" : "event_id"] as? String) == editorialID &&
                    ($0["revision"] as? Int ?? 0) == revision
            }.sorted {
                let revA = $0["revision"] as? Int ?? 0, revB = $1["revision"] as? Int ?? 0
                if revA != revB { return revA > revB }
                let timeField = project == "ttendencias" ? "explained_at" : "prepared_at"
                return ($0[timeField] as? String ?? "") > ($1[timeField] as? String ?? "")
            }
            guard let row = matches.first else {
                throw GitHubError.message("No consta ninguna ficha histórica con ese ID y revisión exactos. No se asociará por nombre.")
            }
            let canonical: String
            if project == "ttendencias" {
                canonical = row["explanation"] as? String ?? ""
                // Deliberately no freshness, group-leader, decision or Listas
                // state guard. A past explained/published/deleted editorial card
                // can still receive an image without being returned to Listas.
                guard !(row["explained_at"] as? String ?? "").isEmpty else {
                    throw GitHubError.message("La ficha histórica no conserva su fecha editorial.")
                }
            } else {
                let tweet = row["tweet"] as? [String: Any] ?? [:]
                canonical = (tweet["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ??
                    (row["explanation"] as? String).flatMap { $0.isEmpty ? nil : $0 } ??
                    row["factual_summary"] as? String ?? ""
            }
            guard canonical == editorialText else {
                throw GitHubError.message("El texto editorial cambió; actualiza la ficha.")
            }
            // Decisions affect visibility/publication, NOT whether the editor
            // may store an image with this historical editorial identity.
            return row
        }
        func api(_ filePath: String, method: String = "GET",
                 body: [String: Any]? = nil) async throws -> (Data, Int) {
            var target = URLComponents(string:
                "https://api.github.com/repos/fabricelop/europapress-rss/contents/" + filePath)!
            if method == "GET" { target.queryItems = [.init(name: "ref", value: "main")] }
            let url = target.url!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 60)
            request.httpMethod = method
            request.setValue("Bearer " + auth, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let session = URLSession(configuration: .ephemeral,
                delegate: EditorialRelationsNoRedirect(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (bytes, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.url?.scheme == "https", http.url?.host == "api.github.com",
                  http.url?.path == url.path else {
                throw GitHubError.message("GitHub rechazó o redirigió la operación.")
            }
            return (bytes, http.statusCode)
        }
        let row = try await currentRow()
        let (already, imageCode) = try await api(path)
        if imageCode == 200 {
            let info = try JSONSerialization.jsonObject(with: already) as? [String: Any] ?? [:]
            // GitHub Contents omits inline bytes for files >1 MB. The immutable
            // Git Blob endpoint remains usable up to the GitHub file limit.
            guard let blobSHA = info["sha"] as? String,
                  blobSHA.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
            else { throw GitHubError.message("El PNG existente no tiene SHA Git verificable.") }
            let blobURL = URL(string:
                "https://api.github.com/repos/fabricelop/europapress-rss/git/blobs/" + blobSHA)!
            var probe = URLRequest(url: blobURL, timeoutInterval: 25)
            probe.setValue("Bearer " + auth, forHTTPHeaderField: "Authorization")
            probe.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (blob, response) = try await URLSession.shared.data(for: probe)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let meta = try JSONSerialization.jsonObject(with: blob) as? [String: Any],
                  let encoded = meta["content"] as? String,
                  let old = Data(base64Encoded:
                    encoded.replacingOccurrences(of: "\n", with: ""), options: .ignoreUnknownCharacters),
                  SHA256.hash(data: old).map({ String(format: "%02x", $0) }).joined() == hex
            else { throw GitHubError.message("El PNG existente no coincide con los bytes solicitados.") }
        } else if imageCode == 404 {
            let (_, code) = try await api(path, method: "PUT", body: [
                "message": "TTActualidad imagen manual " + editorialID + " r" + String(revision),
                "content": png.base64EncodedString(), "branch": "main",
            ])
            guard code == 201 else {
                throw GitHubError.message("GitHub rechazó el PNG: HTTP " + String(code))
            }
        } else { throw GitHubError.message("GitHub no pudo consultar la imagen.") }
        // Recheck the same historical ID/revision/text after upload. An ordinary
        // removal from Listas does not make this image assignment invalid.
        _ = try await currentRow()
        let stampField = project == "ttendencias" ? "explained_at" : "prepared_at"
        guard let at = row[stampField] as? String, !at.isEmpty else {
            throw GitHubError.message("La fecha editorial es necesaria.")
        }
        let record: [String: Any] = project == "ttendencias" ? [
            "target_id": editorialID, "revision": revision, "explained_at": at,
            "explanation": editorialText, "image_url": originalURL.absoluteString, "sha256": hex,
        ] : [
            "target_id": editorialID, "revision": revision, "prepared_at": at,
            "editorial_text": editorialText, "image_url": originalURL.absoluteString, "sha256": hex,
        ]
        var committed = false
        for _ in 0..<4 {
            let (response, code) = try await api(manifestPath)
            guard code == 200,
                  let wrapper = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let previousSha = wrapper["sha"] as? String,
                  let encoded = wrapper["content"] as? String,
                  let content = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: ""),
                                     options: .ignoreUnknownCharacters),
                  var manifest = try JSONSerialization.jsonObject(with: content) as? [String: Any],
                  (manifest["schema_version"] as? Int) == 1,
                  (project == "ttendencias"
                   ? manifest["project_id"] as? String == "appgprj_6ae4dcf7d7488191a574e5b649e67370"
                   : manifest["project"] as? String == "ttittulares"),
                  var images = manifest["images"] as? [[String: Any]] else {
                throw GitHubError.message("Manifiesto del Site incompatible.")
            }
            if images.contains(where: {
                ($0["target_id"] as? String) == editorialID &&
                ($0["revision"] as? Int ?? -1) == revision &&
                ($0["sha256"] as? String) == hex &&
                ($0["image_url"] as? String) == originalURL.absoluteString
            }) {
                committed = true // Idempotent retry: do not rewrite the catalog.
                break
            }
            images.removeAll { ($0["target_id"] as? String) == editorialID &&
                ($0["revision"] as? Int ?? -1) == revision }
            images.insert(record, at: 0)
            manifest["images"] = images
            let updated = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            let (_, writeCode) = try await api(manifestPath, method: "PUT", body: [
                "message": "TTActualidad asociar imagen manual " + editorialID,
                "content": updated.base64EncodedString(), "sha": previousSha,
                "branch": "main",
            ])
            if writeCode == 200 { committed = true; break }
            if writeCode != 409 {
                throw GitHubError.message("No se guardó asociación: HTTP " + String(writeCode))
            }
        }
        guard committed else { throw GitHubError.message("Conflicto de edición del catálogo. Reintenta.") }
        let check = try await readMainJSON(manifestPath)
        guard (check["images"] as? [[String: Any]] ?? []).contains(where: {
            ($0["target_id"] as? String) == editorialID &&
            ($0["revision"] as? Int) == revision &&
            ($0["sha256"] as? String) == hex &&
            ($0["image_url"] as? String) == originalURL.absoluteString
        }) else { throw GitHubError.message("La asociación sigue pendiente de lectura.") }
        return originalURL
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

    // Rebuild the *display* news inbox from retained editorial history, not
    // the transient Listas or the often-empty prepared.json. Opaque relation
    // identities can ONLY come from Sites /v1/snapshot. This method NEVER
    // manufactures an episodeFingerprint or a publication confirmation.
    func editorialRelationRecentNews() async throws -> [EditorialRelationEndpoint] {
        async let preparedRead = readMainJSON("ttittulares/prepared.json")
        async let processedRead = readMainJSON("telegram/editorial-processing.json")
        async let publishedRead = readMainJSON("pilot/ttactualidad-publication-events.json")
        async let radarRead = readMainJSON("ttittulares/status.json")

        let prepared = try? await preparedRead
        let processed = try? await processedRead
        let published = try? await publishedRead
        let radar = try? await radarRead
        guard prepared != nil || processed != nil || published != nil else {
            throw GitHubError.message("No está accesible el historial reciente de noticias.")
        }

        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let latest = Date().addingTimeInterval(300)
        let radarEvents = radar?["events"] as? [String: [String: Any]] ?? [:]
        struct Candidate {
            var id: String
            var revision: Int
            var title: String
            var text: String
            var issuedAt: Date
        }
        var entries: [String: Candidate] = [:]
        func add(_ id: String, _ revision: Int, _ title: String,
                 _ text: String, _ dateValue: String?) {
            guard !id.isEmpty, revision >= 0,
                  let date = EditorialRelationsPolicy.parsedDate(dateValue),
                  date >= cutoff, date <= latest,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let key = EditorialRelationsPolicy.newsKey(id: id, revision: revision)
            let candidate = Candidate(id: id, revision: revision, title: title,
                                      text: text, issuedAt: date)
            if let previous = entries[key] {
                entries[key] = Candidate(
                    id: id, revision: revision,
                    title: title.count > previous.title.count ? title : previous.title,
                    text: text.count > previous.text.count ? text : previous.text,
                    issuedAt: max(date, previous.issuedAt))
            } else { entries[key] = candidate }
        }

        // READY is retained after removal from Listas; PROCESSING is not a
        // final news episode and must not leak into editorial relationship UI.
        for row in processed?["items"] as? [[String: Any]] ?? [] {
            guard row["status"] as? String == "READY",
                  let id = row["event_id"] as? String,
                  let revision = row["revision"] as? Int,
                  let title = row["title"] as? String else { continue }
            let date = row["delivered_at"] as? String ??
                row["rewrite_completed_at"] as? String ?? row["selected_at"] as? String
            add(id, revision, title, "", date)
        }

        // Publication events are durable even when both prepared and Listas
        // are empty. Only join title by the SAME event ID AND revision.
        for row in published?["items"] as? [[String: Any]] ?? [] {
            guard row["project"] as? String == "ttittulares",
                  let id = row["event_id"] as? String,
                  let revision = row["revision"] as? Int,
                  let radarRow = radarEvents[id],
                  radarRow["revision"] as? Int == revision,
                  let title = radarRow["title"] as? String else { continue }
            add(id, revision, title, "", row["at"] as? String)
        }

        // Prepared is still useful while populated, but it is NOT a
        // requirement for the inbox to contain recent articles.
        for row in prepared?["items"] as? [[String: Any]] ?? [] {
            guard let id = row["event_id"] as? String,
                  let revision = row["revision"] as? Int,
                  let title = row["title"] as? String else { continue }
            let tweet = row["tweet"] as? [String: Any] ?? [:]
            let text = (tweet["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ??
                (row["explanation"] as? String) ??
                (row["factual_summary"] as? String) ?? ""
            add(id, revision, title, text, row["prepared_at"] as? String)
        }

        return entries.values.sorted {
            if $0.issuedAt != $1.issuedAt { return $0.issuedAt > $1.issuedAt }
            if $0.revision != $1.revision { return $0.revision > $1.revision }
            return $0.id < $1.id
        }.map {
            EditorialRelationEndpoint(
                id: $0.id, revision: $0.revision, episodeFingerprint: "",
                title: $0.title, text: $0.text, path: nil,
                listedAt: ISO8601DateFormatter().string(from: $0.issuedAt))
        }
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

    func setTrendImportance(name: String, important: Bool) async -> Bool {
        guard authenticated else {
            notice = "Conecta GitHub para marcar una tendencia como importante."
            return false
        }
        let key = "trend-importance:" + TrendImportance.key(name)
        guard !inFlightKeys.contains(key) else { return false }
        inFlightKeys.insert(key)
        defer { inFlightKeys.remove(key) }
        do {
            var request = URLRequest(url: TrendImportance.endpoint,
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.httpMethod = "POST"
            request.setValue("Bearer " + (try await authorizedToken()), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("TTActualidad/0.4.51", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "important": important])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try TrendImportance.confirms(data, name: name, important: important) else {
                throw GitHubError.message("No se ha confirmado la marca. Actualiza el Top 30 y vuelve a intentarlo.")
            }
            notice = important ? "Tendencia marcada como Importante en APP y web." : "Marca Importante retirada."
            return true
        } catch {
            notice = error.localizedDescription
            return false
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
    func submitTrendHints(project: String = "ttendencias", eventID: String, revision: Int, title: String,
                          rank: Int, hints: String, requestID: String) async -> WriteResult {
        let text = hints.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 && text.count <= 6000,
              !eventID.isEmpty && revision >= 0 else {
            notice = "Escribe entre 8 y 6000 caracteres de pistas y comprueba la ficha."
            return .failed
        }
        return await dispatch("ttactualidad_action_v1", payload: [
            "project": project, "event_id": eventID, "revision": revision,
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

    func groupListas(requestID: String, removeCovered: [TrendItem]? = nil, selected: [TrendItem]? = nil) async -> WriteResult {
        var payload: [String: Any] = [
            "project": "ttendencias", "event_id": "listas-grouping",
            "request_id": requestID,
            "decision": removeCovered == nil ? "group_listas" : "remove_covered"
        ]
        if let items = removeCovered ?? selected {
            payload["items"] = items.map { ["id": $0.editorialID, "revision": $0.revision] as [String: Any] }
        }
        return await dispatch("ttactualidad_group_listas_v1", payload: payload,
                              label: removeCovered == nil ? "Agrupar Listas" : "Retirar agrupadas")
    }

    // One GitHub receipt for the complete snapshot, not one API call per card.
    // Revisions are checked again by the authoritative Listas workflow.
    func removeAllTrendsFromListas(items: [TrendItem], requestID: String) async -> WriteResult {
        guard !items.isEmpty && items.count <= 500 else {
            notice = "No hay tendencias para retirar o la selección supera las 500."
            return .failed
        }
        let payload: [String: Any] = [
            "project": "ttendencias", "event_id": "listas-remove-all",
            "decision": "remove_all_trends", "request_id": requestID,
            "items": items.map {
                ["id": $0.editorialID, "revision": $0.revision] as [String: Any]
            }
        ]
        let result = await dispatch("ttactualidad_group_listas_v1", payload: payload,
                                    label: "Retirar todas las tendencias · No publicadas")
        // An explicitly rejected receipt is not a still-pending dispatch.
        // Preserve retry ID only when the outcome is truly uncertain.
        if case .pending = result {
            if let receiptDocument = try? await readMainJSON("pilot/ttactualidad-action-receipts.json"),
               let receipt = (receiptDocument["items"] as? [[String: Any]])?.first(where: {
                   ($0["request_id"] as? String) == requestID
               }), (receipt["status"] as? String) == "rejected" {
                notice = (receipt["error"] as? String) ??
                    "La selección ha cambiado. Actualiza Listas y vuelve a intentarlo."
                return .failed
            }
        }
        return result
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

