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
