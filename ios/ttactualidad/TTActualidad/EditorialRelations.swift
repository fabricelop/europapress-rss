import Foundation

// Server-issued identities are opaque. Never infer a relationship from a rank,
// title, or an image approval; both ends refer to one exact editorial episode.
struct EditorialRelationEndpoint: Codable, Identifiable, Equatable {
    let id: String
    let revision: Int
    let episodeFingerprint: String
    let title: String
    let text: String
    let path: String?
    // Optional server-issued moment when this news last entered Listas.
    // Without it the APP preserves source order; it never invents a date.
    let listedAt: String?

    init(id: String, revision: Int, episodeFingerprint: String,
         title: String, text: String, path: String?, listedAt: String? = nil) {
        self.id = id
        self.revision = revision
        self.episodeFingerprint = episodeFingerprint
        self.title = title
        self.text = text
        self.path = path
        self.listedAt = listedAt
    }

    var stableIdentity: String {
        [id, String(revision), episodeFingerprint].joined(separator: "|")
    }

    var identity: EditorialRelationIdentity {
        EditorialRelationIdentity(id: id, revision: revision,
                                  episodeFingerprint: episodeFingerprint)
    }
}

struct EditorialRelationIdentity: Codable, Equatable {
    let id: String
    let revision: Int
    let episodeFingerprint: String
}

struct EditorialRelation: Decodable, Identifiable {
    let id: String
    let news: EditorialRelationEndpoint
    let trend: EditorialRelationEndpoint
    let state: String
    let origin: String
    let reason: String
}

struct EditorialRelationsSnapshot: Decodable {
    let items: [EditorialRelation]
    let news: [EditorialRelationEndpoint]
    let trends: [EditorialRelationEndpoint]
}

struct EditorialRelationDecision: Encodable {
    let action: String
    let expectedNews: EditorialRelationIdentity
    let expectedTrend: EditorialRelationIdentity
    let commandId: String
}

struct EditorialRelationReceipt: Decodable {
    let state: String
    let relationId: String
}

enum EditorialRelationsPolicy {
    static func newsKey(id: String, revision: Int) -> String {
        id + ":r" + String(revision)
    }

    // The normal Relations screen only lists actual READY/Listas news.
    // Explicit selection can still inspect/edit a historical news episode.
    static func isVisibleNews(_ news: EditorialRelationEndpoint,
                              activeListas: Set<String>,
                              explicit: EditorialRelationEndpoint?) -> Bool {
        activeListas.contains(newsKey(id: news.id, revision: news.revision)) ||
            (explicit?.stableIdentity == news.stableIdentity)
    }

    // Only episodes with an authenticated editorial timestamp belong in the
    // 12/24h inbox. Missing timestamps remain available through manual search,
    // never silently labelled as recent. A news item can be outside Listas.
    static func parsedDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func recentNews(_ candidates: [EditorialRelationEndpoint],
                           hours: Int = 12, now: Date = Date(),
                           fallbackDates: [String: Date] = [:],
                           hidden: Set<String> = []) -> [EditorialRelationEndpoint] {
        let interval = TimeInterval(max(1, min(48, hours))) * 3600
        let cutoff = now.addingTimeInterval(-interval)
        var rows: [(episode: EditorialRelationEndpoint, date: Date)] = []
        var seen = Set<String>()
        for candidate in candidates {
            let key = newsKey(id: candidate.id, revision: candidate.revision)
            // GitHub-only rows have NO fingerprint and are view-only until the
            // relationship backend provides their original episode identity.
            guard !hidden.contains(candidate.stableIdentity),
                  !hidden.contains(key),
                  let date = parsedDate(candidate.listedAt) ?? fallbackDates[key],
                  date >= cutoff, date <= now.addingTimeInterval(300),
                  seen.insert(candidate.stableIdentity).inserted else { continue }
            rows.append((candidate, date))
        }
        rows.sort { a, b in
            if a.date != b.date { return a.date > b.date }
            if a.episode.revision != b.episode.revision {
                return a.episode.revision > b.episode.revision
            }
            return a.episode.id < b.episode.id
        }
        // Never show duplicate versions of the same article in the primary
        // review queue; the manual historical picker still shows episodes.
        var newsIDs = Set<String>()
        return rows.compactMap { row in
            newsIDs.insert(row.episode.id).inserted ? row.episode : nil
        }
    }

    // Only explicit switches write decisions. Suggested (unaccepted) pairs are
    // not automatically dismissed when an editor saves another Top30 link.
    // A Sites-issued episode fingerprint already guards the exact editorial
    // identity at write time. Rank text may vary in presentation independently
    // (TT# prefix, whitespace). Prefer exact text when available; for one
    // unambiguous ID+revision candidate, allow it and let Sites verify the
    // fingerprint. Never choose arbitrarily between distinct episodes.
    static func matchingTop30Endpoint(
        id: String, revision: Int, renderedText: String,
        candidates: [EditorialRelationEndpoint]
    ) -> EditorialRelationEndpoint? {
        guard !id.isEmpty else { return nil }
        let matches = candidates.filter {
            $0.id == id && $0.revision == revision && !$0.episodeFingerprint.isEmpty
        }
        if let exact = matches.first(where: { $0.text == renderedText }) {
            return exact
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func actionForSwitch(current: String?, selected: Bool) -> String? {
        let linked = current == "linked"
        if linked == selected { return nil }
        return selected ? "link" : "unlink"
    }

    // Defensive display reconciliation: a partial sync may repeat a pair.
    // Prefer explicit manual decisions to automatic proposals; if conflicting
    // states still arrive, a block wins rather than silently re-linking.
    // Server receipts remain authoritative; this never writes decisions.
    static func canonical(_ items: [EditorialRelation]) -> [EditorialRelation] {
        var keys: [String] = []
        var byKey: [String: EditorialRelation] = [:]
        for item in items {
            let key = item.news.stableIdentity + "↔" + item.trend.stableIdentity
            if let previous = byKey[key] {
                if precedence(item) > precedence(previous) { byKey[key] = item }
            } else {
                keys.append(key)
                byKey[key] = item
            }
        }
        return keys.compactMap { byKey[$0] }
    }

    private static func precedence(_ item: EditorialRelation) -> Int {
        let manual = item.origin == "manual" ? 100 : 0
        let state: Int
        switch item.state {
        case "blocked": state = 30
        case "linked": state = 20
        case "suggested": state = 10
        default: state = 0
        }
        return manual + state
    }

    static func confirms(_ receipt: EditorialRelationReceipt, action: String) -> Bool {
        guard !receipt.relationId.isEmpty else { return false }
        return action == "link" ? receipt.state == "linked" :
            ["unlink", "dismiss"].contains(action) && receipt.state == "blocked"
    }

    static func matches(_ endpoint: EditorialRelationEndpoint,
                        id: String, revision: Int) -> Bool {
        endpoint.id == id && endpoint.revision == revision &&
            !endpoint.episodeFingerprint.isEmpty
    }
}
