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

    // The Site v85 can return legacy rows with no optional fingerprint,
    // display text or timestamp. Do not discard all real relations because
    // a non-identity presentation field was absent. IDs/revisions stay strict.
    private enum CodingKeys: String, CodingKey {
        case id, revision, episodeFingerprint, title, text, path, listedAt
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(String.self, forKey: .id)
        revision = try value.decode(Int.self, forKey: .revision)
        episodeFingerprint = try value.decodeIfPresent(
            String.self, forKey: .episodeFingerprint) ?? ""
        title = try value.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try value.decodeIfPresent(String.self, forKey: .text) ?? ""
        path = try value.decodeIfPresent(String.self, forKey: .path)
        listedAt = try value.decodeIfPresent(String.self, forKey: .listedAt)
    }

    var stableIdentity: String {
        [id, String(revision), episodeFingerprint].joined(separator: "|")
    }

    var identity: EditorialRelationIdentity {
        EditorialRelationIdentity(id: id, revision: revision,
                                  episodeFingerprint: episodeFingerprint.isEmpty ?
                                  nil : episodeFingerprint)
    }
}

struct EditorialRelationIdentity: Codable, Equatable {
    let id: String
    let revision: Int
    // A fingerprint is an optional additional check; an exact ID/revision
    // remains addressable even for historical episodes without that field.
    let episodeFingerprint: String?
}

struct EditorialRelation: Decodable, Identifiable {
    let id: String
    let news: EditorialRelationEndpoint
    let trend: EditorialRelationEndpoint
    let state: String
    let origin: String
    let reason: String

    private enum CodingKeys: String, CodingKey {
        case id, news, trend, state, origin, reason
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(String.self, forKey: .id)
        news = try value.decode(EditorialRelationEndpoint.self, forKey: .news)
        trend = try value.decode(EditorialRelationEndpoint.self, forKey: .trend)
        state = try value.decode(String.self, forKey: .state)
        origin = try value.decodeIfPresent(String.self, forKey: .origin) ?? ""
        reason = try value.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

struct EditorialRelationsSnapshot: Decodable {
    let items: [EditorialRelation]
    let news: [EditorialRelationEndpoint]
    let trends: [EditorialRelationEndpoint]

    private enum CodingKeys: String, CodingKey {
        case items, news, trends
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        items = try value.decodeIfPresent([EditorialRelation].self,
                                          forKey: .items) ?? []
        news = try value.decodeIfPresent([EditorialRelationEndpoint].self,
                                         forKey: .news) ?? []
        trends = try value.decodeIfPresent([EditorialRelationEndpoint].self,
                                           forKey: .trends) ?? []
    }
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

    // A relationship always targets the two exact editorial IDs/revisions.
    // A server-issued fingerprint is an additional write-time guard, not a
    // reason for a visible checkbox to lose its state after snapshot refresh.
    static func pairKey(_ news: EditorialRelationEndpoint,
                        _ trend: EditorialRelationEndpoint) -> String {
        newsKey(id: news.id, revision: news.revision) + "↔" +
            newsKey(id: trend.id, revision: trend.revision)
    }

    // Sites v85 can expose the same exact pair through an older automatic
    // suggestion AND a manual confirmed relation, with different fingerprints.
    // Their identity is still (news ID/rev, trend ID/rev): the manual state wins.
    // Never let a later suggested row overwrite a confirmed checkbox.
    static func effectivePairStates(_ items: [EditorialRelation]) -> [String: String] {
        var best: [String: EditorialRelation] = [:]
        for item in items {
            let key = pairKey(item.news, item.trend)
            if let previous = best[key] {
                if precedence(item) > precedence(previous) { best[key] = item }
            } else {
                best[key] = item
            }
        }
        return best.mapValues { $0.state }
    }

    static func confirmedCount(_ items: [EditorialRelation],
                               trendID: String, revision: Int) -> Int {
        guard !trendID.isEmpty else { return 0 }
        let states = effectivePairStates(items)
        return Set(items.compactMap { relation -> String? in
            guard relation.trend.id == trendID,
                  relation.trend.revision == revision,
                  states[pairKey(relation.news, relation.trend)] == "linked"
            else { return nil }
            return newsKey(id: relation.news.id, revision: relation.news.revision)
        }).count
    }

    // A successful POST is not proof the relationship is visible on the Site.
    // Confirm readback from the private authoritative snapshot before clearing
    // a pending checkbox or reporting a saved relationship to the editor.
    static func persisted(_ items: [EditorialRelation],
                          news: EditorialRelationEndpoint,
                          trend: EditorialRelationEndpoint, action: String) -> Bool {
        let wanted = action == "link" ? "linked" : "blocked"
        return canonical(items).contains { row in
            row.state == wanted &&
                row.news.id == news.id && row.news.revision == news.revision &&
                row.trend.id == trend.id && row.trend.revision == trend.revision &&
                (news.episodeFingerprint.isEmpty ||
                 row.news.episodeFingerprint.isEmpty ||
                 news.episodeFingerprint == row.news.episodeFingerprint) &&
                (trend.episodeFingerprint.isEmpty ||
                 row.trend.episodeFingerprint.isEmpty ||
                 trend.episodeFingerprint == row.trend.episodeFingerprint)
        }
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

    // Display discovery is based on the actual text of each news episode, not
    // a presumed editorial association. It never writes or invents a relation.
    // Search accent/case-insensitively, but require word boundaries so short
    // trend names cannot match unrelated fragments of longer words.
    static func newsMentionsTrend(_ news: EditorialRelationEndpoint, name: String) -> Bool {
        let locale = Locale(identifier: "es_ES")
        func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        }
        let term = normalized(name.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return false }
        let content = normalized(news.title + " " + news.text)
        let pattern = "(?<![\\p{L}\\p{N}])" +
            NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
        return content.range(of: pattern, options: .regularExpression) != nil
    }

    // Search all known editorial news for a trend, with no date cutoff,
    // hidden-state exclusions, or dependency on Listas membership. Only the
    // five best textual matches are presented; selection remains explicit.
    static func newsForTrend(_ candidates: [EditorialRelationEndpoint],
                             name: String, now: Date = Date(),
                             fallbackDates: [String: Date] = [:],
                             hidden: Set<String> = [], limit: Int = 5)
        -> [EditorialRelationEndpoint] {
        let matching = candidates.compactMap { news -> (EditorialRelationEndpoint, Date?)? in
            let key = newsKey(id: news.id, revision: news.revision)
            guard newsMentionsTrend(news, name: name) else { return nil }
            return (news, parsedDate(news.listedAt) ?? fallbackDates[key])
        }.sorted { left, right in
            let leftDate = left.1 ?? .distantPast
            let rightDate = right.1 ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            if left.0.revision != right.0.revision {
                return left.0.revision > right.0.revision
            }
            return left.0.id < right.0.id
        }
        var ids = Set<String>()
        return Array(matching.compactMap {
            ids.insert($0.0.id).inserted ? $0.0 : nil
        }.prefix(max(0, min(5, limit))))
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
            $0.id == id && $0.revision == revision
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
        endpoint.id == id && endpoint.revision == revision
    }
}
