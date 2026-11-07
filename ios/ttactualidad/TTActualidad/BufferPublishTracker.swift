import Foundation
import Combine

// Separate from existing "24 h publicados" (manual editorial decisions).
// The Buffer counter NEVER counts a dispatch, a scheduled job or an X compose URL.
struct TTBufferPublication: Decodable {
    let request_id: String
    let project: String
    let event_id: String
    let revision: Int
    let account: String
    let state: String
    let sent_at: String?
    let post_url: String?
    let media_type: String?
    let closure_verified: Bool?
    let closure_error: String?
    let verification_note: String?
    let error: String?
}

// The Buffer API returns one pooled quota for all unlocked channels.
// 30 days is a rolling window, not a calendar month.
struct TTBufferAPIQuota: Decodable {
    let limit: Int
    let remaining: Int
    let used: Int
    let window_seconds: Int
    let resets_in_seconds: Int
    let observed_at: String
}

private struct TTBufferLedger: Decodable {
    let items: [TTBufferPublication]
    let api_quota: TTBufferAPIQuota?
}

@MainActor
final class BufferPublishTracker: ObservableObject {
    @Published private(set) var posts: [TTBufferPublication] = []
    @Published private(set) var loaded = false
    // A GitHub 204 dispatch only acknowledges transport. Unless the default
    // branch exposes the publisher's verified ledger, a button tap MUST NOT
    // pretend a Buffer/X publisher exists.
    @Published private(set) var backendAvailable = false
    @Published private(set) var apiQuota: TTBufferAPIQuota?
    @Published private(set) var notice = ""
    @Published private(set) var change = 0
    @Published private(set) var sending = Set<String>()
    // An in-memory visual reservation, NOT a GitHub or X publication receipt.
    @Published private(set) var immediateHide = Set<String>()

    private static func key(_ project: String, _ id: String, _ revision: Int) -> String {
        project + ":" + id + ":r" + String(revision)
    }

    // The tap removes the item visually before the network round trip.
    // The authoritative Listas store stays unchanged; failed / timed-out
    // requests restore the row automatically.
    func stagePublish(project: String, id: String, revision: Int) {
        immediateHide.insert(Self.key(project, id, revision))
    }

    func hidesFromListas(project: String, id: String, revision: Int) -> Bool {
        let key = Self.key(project, id, revision)
        return immediateHide.contains(key) || posts.contains {
            $0.project == project && $0.event_id == id &&
            $0.revision == revision && $0.state == "sent" &&
            $0.closure_verified == true
        }
    }

    // Receipt survives reopening the editorial card. A pending dispatch is
    // never presented as X publication; only Buffer's confirmed ledger is.
    func latestReceipt(project: String, id: String,
                       revision: Int) -> TTBufferPublication? {
        posts.last {
            $0.project == project && $0.event_id == id &&
            $0.revision == revision
        }
    }

    func alreadySent(project: String, id: String, revision: Int) -> Bool {
        posts.contains {
            $0.project == project && $0.event_id == id &&
            $0.revision == revision && $0.state == "sent"
        }
    }

    func blocked(project: String, id: String, revision: Int) -> Bool {
        sending.contains(Self.key(project, id, revision)) || posts.contains {
            $0.project == project && $0.event_id == id &&
            $0.revision == revision &&
            ["reserved", "unknown", "pending", "sent"].contains($0.state)
        }
    }

    private func confirmedDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let basic = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return basic.date(from: raw) ?? fractional.date(from: raw)
    }

    func totalSent(account: String) -> Int {
        posts.filter { $0.account == account && $0.state == "sent" }.count
    }

    func sentLast24Hours(account: String, now: Date = Date()) -> Int {
        posts.filter { post in
            guard post.account == account, post.state == "sent",
                  let date = confirmedDate(post.sent_at) else { return false }
            let elapsed = now.timeIntervalSince(date)
            return elapsed >= 0 && elapsed < 86400
        }.count
    }

    func sentLast30Days(account: String, now: Date = Date()) -> Int {
        posts.filter { post in
            guard post.account == account, post.state == "sent",
                  let date = confirmedDate(post.sent_at) else { return false }
            let elapsed = now.timeIntervalSince(date)
            return elapsed >= 0 && elapsed < 30 * 86400
        }.count
    }

    func pending(account: String) -> Int {
        posts.filter {
            $0.account == account &&
            ["reserved", "unknown", "pending"].contains($0.state)
        }.count
    }

    // Public, read-only GitHub ledger. The Buffer key stays server-side in
    // GitHub Actions Secrets, never in a mobile binary or network request.
    func refresh() async {
        backendAvailable = false
        var components = URLComponents(string:
            "https://raw.githubusercontent.com/fabricelop/europapress-rss/main/pilot/ttactualidad-buffer-posts.json")!
        components.queryItems = [URLQueryItem(name: "readback", value: UUID().uuidString)]
        guard let url = components.url else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let ledger = try JSONDecoder().decode(TTBufferLedger.self, from: data)
            posts = ledger.items
            apiQuota = ledger.api_quota
            loaded = true
            backendAvailable = true
        } catch {
            // An outdated or unreachable readback is not proof of publication.
            // Preserve the previous verified values and mark unavailable initially.
        }
    }

    // A distinct user tap is the one and only authorization to publish this
    // editorial item. Buffer itself is never invoked by refresh() or polling.
    func publish(github: GitHubEditor, project: String, id: String,
                 revision: Int) async {
        let key = Self.key(project, id, revision)
        guard github.authenticated else {
            immediateHide.remove(key)
            notice = "Conecta GitHub antes de publicar directamente."
            change += 1
            return
        }
        guard ["ttittulares", "ttendencias"].contains(project),
              !id.isEmpty && revision >= 0 else {
            immediateHide.remove(key)
            notice = "Identidad editorial no confirmada. Actualiza la ficha."
            change += 1
            return
        }
        // First verify the Buffer receipt source exists on main. This is
        // deliberately fail-closed; no request is submitted on 404/error.
        await refresh()
        guard backendAvailable else {
            immediateHide.remove(key)
            notice = "Buffer aún no está activado en GitHub. No se ha enviado nada a X; la ficha permanece en Listas."
            change += 1
            return
        }
        if blocked(project: project, id: id, revision: revision) {
            immediateHide.remove(key)
            notice = "Esta revisión ya está publicada o pendiente. No se duplicará."
            change += 1
            return
        }
        let account = project == "ttittulares" ? "@ttittulares" : "@ttendenciasesp"
        let requestID = UUID().uuidString.lowercased()
        immediateHide.insert(key)
        sending.insert(key)
        notice = "Enviando solicitud a " + account + "; aún no se ha publicado."
        change += 1

        let result = await github.dispatch("ttactualidad_buffer_publish_v1", payload: [
            "project": project, "event_id": id, "revision": revision,
            "request_id": requestID
        ], label: "Publicar directo en " + account)
        if result == .failed {
            sending.remove(key)
            immediateHide.remove(key)
            notice = github.notice
            change += 1
            return
        }
        notice = "Orden aceptada por GitHub para " + account +
            ". Esperando el recibo verificado de Buffer y el enlace real de X."
        change += 1
        Task { await followReceipt(requestID: requestID, project: project, id: id,
                                   revision: revision, key: key) }
    }

    private func followReceipt(requestID: String, project: String, id: String,
                               revision: Int, key: String) async {
        defer { sending.remove(key) }
        for attempt in 0..<20 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(7)) }
            await refresh()
            if let receipt = posts.last(where: { $0.request_id == requestID &&
                $0.project == project && $0.event_id == id && $0.revision == revision }) {
                switch receipt.state {
                case "sent":
                    if receipt.closure_verified == true {
                        immediateHide.remove(key)
                        notice = "Publicado en X y retirado de Listas · @" + receipt.account
                        if let url = receipt.post_url { notice += " · " + url }
                        change += 1
                        return
                    }
                    notice = "Buffer confirmó X, pero falta la retirada de Listas. " +
                             "La ficha sigue oculta provisionalmente."
                    if let url = receipt.post_url { notice += " · " + url }
                    change += 1
                    // Continue checking the *separate* closure receipt, never repost.
                    continue
                case "failed":
                    immediateHide.remove(key)
                    notice = "No publicada: " + (receipt.error ?? "Buffer rechazó la orden.")
                    change += 1
                    return
                case "unknown":
                    immediateHide.remove(key)
                    notice = "Resultado incierto: comprueba X antes de intentar otra publicación."
                    change += 1
                    return
                default:
                    break
                }
            }
        }
        immediateHide.remove(key)
        notice = "No hay cierre confirmado. La ficha vuelve a Listas si GitHub sigue mostrándola; consulta el estado de Buffer antes de reintentar."
        change += 1
    }
}
