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
