import Foundation

/// Classifies aged local commands for audit; never changes server state.
/// Missing receipts are NOT proof of success or rejection.
enum EditorialPendingPolicy {
    static let archivalAge: TimeInterval = 6 * 60 * 60
    static let unidentifiedAge: TimeInterval = 24 * 60 * 60

    static func canArchive(age: TimeInterval, receiptsFresh: Bool,
                           queueFresh: Bool, decisionsFresh: Bool,
                           hasReceipt: Bool, activeInQueue: Bool) -> Bool {
        age >= archivalAge && receiptsFresh && queueFresh && decisionsFresh &&
            !hasReceipt && !activeInQueue
    }
}


// One editorial occurrence can be removed from Pendientes without suppressing
// its literal term, hiding its Top 30 ranking, or counting a publication.
struct TrendPendingRetirement: Equatable {
    let editorialID: String
    let revision: Int
    let name: String
    let retiredAt: Date
}

enum TrendPendingRemovalPolicy {
    private static func nameKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "es_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func isVisible(id: String, revision: Int, name: String,
                          enteredAt: Date?,
                          retirements: [TrendPendingRetirement]) -> Bool {
        let key = nameKey(name)
        guard !key.isEmpty else { return true }
        // A previously retired item cannot be reconstructed merely because
        // an old inactive/problematic request is still present in requests.json.
        let candidates = retirements.filter { nameKey($0.name) == key }
        guard let latest = candidates.max(by: { $0.retiredAt < $1.retiredAt }) else {
            return true
        }
        // Only a GENUINELY new entry into the Top 30 (not a later scraping
        // timestamp, ranking shift or stale queue) permits reappearance.
        if let enteredAt, enteredAt > latest.retiredAt {
            return true
        }
        return false
    }
}
