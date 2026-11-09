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
    let other_windows: [TTBufferQuotaShortWindow]?
}

private struct TTBufferLedger: Decodable {
    let items: [TTBufferPublication]
    let api_quota: TTBufferAPIQuota?
    let api_quota_history: [TTBufferQuotaObservation]?
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
    @Published private(set) var quotaHistory: [TTBufferQuotaObservation] = []
    @Published private(set) var notice = ""
    @Published private(set) var change = 0
    @Published private(set) var sending = Set<String>()
    // Persist the editor's provisional hide across app restarts. This is
    // neither a publication confirmation nor permission to send another post.
    private static let pendingHideStorageKey = "TTActualidad.bufferPendingHide.v2"
    @Published private(set) var immediateHide = Set<String>(
        UserDefaults.standard.stringArray(forKey: BufferPublishTracker.pendingHideStorageKey) ?? [])
    // X-confirmed transmissions are durable tombstones for Listas. The
    // Buffer ledger read can fail or lag while the app refreshes the other
    // editorial files; that must never resurrect an already sent episode.
    // Only a verified "sent" ledger entry can add a key to this cache.
    private static let confirmedSentStorageKey = "TTActualidad.bufferConfirmedSent.v1"
    private var confirmedSentKeys = Set<String>(
        UserDefaults.standard.stringArray(
            forKey: BufferPublishTracker.confirmedSentStorageKey) ?? [])
    // A stale failed receipt for a PREVIOUS attempt must never unhide a newer
    // pending one. Persist the actual dispatch identity across app restarts.
    private static let pendingRequestIDsKey = "TTActualidad.bufferPendingRequestIds.v1"
    private var pendingRequestIDs: [String: String] =
        UserDefaults.standard.dictionary(
            forKey: BufferPublishTracker.pendingRequestIDsKey) as? [String: String] ?? [:]

    private static func key(_ project: String, _ id: String, _ revision: Int) -> String {
        project + ":" + id + ":r" + String(revision)
    }

    private func persistPendingHide() {
        UserDefaults.standard.set(Array(immediateHide).sorted(),
                                  forKey: Self.pendingHideStorageKey)
    }

    private func clearPendingHide(_ key: String) {
        if immediateHide.remove(key) != nil { persistPendingHide() }
        if pendingRequestIDs.removeValue(forKey: key) != nil {
            UserDefaults.standard.set(pendingRequestIDs,
                                      forKey: Self.pendingRequestIDsKey)
        }
    }

    private func registerPendingRequest(_ key: String, requestID: String) {
        pendingRequestIDs[key] = requestID
        UserDefaults.standard.set(pendingRequestIDs,
                                  forKey: Self.pendingRequestIDsKey)
    }

    // Hide immediately, persist the reservation even after a process exit.
    // Only a definitive failed receipt can restore a provisional row.
    func stagePublish(project: String, id: String, revision: Int) {
        immediateHide.insert(Self.key(project, id, revision))
        persistPendingHide()
    }

    func hidesFromListas(project: String, id: String, revision: Int) -> Bool {
        let key = Self.key(project, id, revision)
        return immediateHide.contains(key) || confirmedSentKeys.contains(key) ||
            posts.contains {
                $0.project == project && $0.event_id == id &&
                $0.revision == revision &&
                ["reserved", "unknown", "pending", "sent"].contains($0.state)
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
        confirmedSentKeys.contains(Self.key(project, id, revision)) ||
            posts.contains {
                $0.project == project && $0.event_id == id &&
                $0.revision == revision && $0.state == "sent"
            }
    }

    func blocked(project: String, id: String, revision: Int) -> Bool {
        alreadySent(project: project, id: id, revision: revision) ||
            pendingRequestIDs[Self.key(project, id, revision)] != nil ||
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
            let confirmed = Set(ledger.items.filter { $0.state == "sent" }.map {
                Self.key($0.project, $0.event_id, $0.revision)
            })
            // Monotonic, exact revision-specific closure. Never clear on a
            // transient empty/stale response; a legitimate later revision
            // remains a separate episode.
            let merged = confirmedSentKeys.union(confirmed)
            if merged != confirmedSentKeys {
                confirmedSentKeys = merged
                UserDefaults.standard.set(Array(merged).sorted(),
                                          forKey: Self.confirmedSentStorageKey)
            }
            // Match the exact dispatch request. An older failed attempt for
            // this episode cannot release a newer pending publication.
            // "sent" is safe: confirmedSentKeys has already been persisted.
            for (key, requestID) in Array(pendingRequestIDs) {
                guard !sending.contains(key),
                      let receipt = ledger.items.last(where: {
                          Self.key($0.project, $0.event_id, $0.revision) == key &&
                          $0.request_id == requestID
                      }) else { continue }
                if receipt.state == "sent" || receipt.state == "failed" {
                    clearPendingHide(key)
                }
            }
            apiQuota = ledger.api_quota
            quotaHistory = ledger.api_quota_history ?? []
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
            clearPendingHide(key)
            notice = "Conecta GitHub antes de publicar directamente."
            change += 1
            return
        }
        guard ["ttittulares", "ttendencias"].contains(project),
              !id.isEmpty && revision >= 0 else {
            clearPendingHide(key)
            notice = "Identidad editorial no confirmada. Actualiza la ficha."
            change += 1
            return
        }
        // First verify the Buffer receipt source exists on main. This is
        // deliberately fail-closed; no request is submitted on 404/error.
        await refresh()
        guard backendAvailable else {
            clearPendingHide(key)
            notice = "Buffer aún no está activado en GitHub. No se ha enviado nada a X; la ficha permanece en Listas."
            change += 1
            return
        }
        if blocked(project: project, id: id, revision: revision) {
            // A remote pending/unknown entry must not reappear after reload.
            if alreadySent(project: project, id: id, revision: revision) {
                clearPendingHide(key)
            }
            notice = "Esta revisión ya está publicada o pendiente. No se duplicará."
            change += 1
            return
        }
        let account = project == "ttittulares" ? "@ttittulares" : "@ttendenciasesp"
        let requestID = UUID().uuidString.lowercased()
        stagePublish(project: project, id: id, revision: revision)
        registerPendingRequest(key, requestID: requestID)
        sending.insert(key)
        notice = "Enviando solicitud a " + account + "; aún no se ha publicado."
        change += 1

        let result = await github.dispatch("ttactualidad_buffer_publish_v1", payload: [
            "project": project, "event_id": id, "revision": revision,
            "request_id": requestID
        ], label: "Publicar directo en " + account)
        if result == .failed {
            sending.remove(key)
            clearPendingHide(key)
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
                        clearPendingHide(key)
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
                    clearPendingHide(key)
                    notice = "No publicada: " + (receipt.error ?? "Buffer rechazó la orden.")
                    change += 1
                    return
                case "unknown":
                    notice = "Resultado incierto: ficha reservada fuera de Listas. Comprueba X antes de actuar."
                    change += 1
                    return
                default:
                    break
                }
            }
        }
        // Poll timeout is not a failure receipt. Keep the local reservation.
        if alreadySent(project: project, id: id, revision: revision) {
            // X already published; never resurface this as a fresh publishable
            // item or resend it. The GitHub Listas receipt remains independent.
            notice = "Buffer confirmó X, pero sigue pendiente el recibo de retirada de Listas. " +
                     "La ficha continúa oculta provisionalmente; no se volverá a publicar."
        } else {
            notice = "Publicación sin recibo definitivo: reservada fuera de Listas. " +
                     "Comprueba Buffer; no se volverá a publicar automáticamente."
        }
        change += 1
    }
}
