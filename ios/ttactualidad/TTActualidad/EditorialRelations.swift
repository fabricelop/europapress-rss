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
