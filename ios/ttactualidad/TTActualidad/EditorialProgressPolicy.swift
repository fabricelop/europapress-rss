import Foundation

// Kept independent of network and SwiftUI so completion/refresh rules can be
// tested without sending editorial orders or changing any real card.
enum EditorialProgressPolicy {
    static func shouldPoll(pendingOrders: Int, newsWorking: Int,
                           trendsWorking: Int, viewingWorking: Bool) -> Bool {
        pendingOrders > 0 || newsWorking > 0 || trendsWorking > 0 || viewingWorking
    }

    static func isPending(queuedRevision: Int, readyRevision: Int?) -> Bool {
        guard let readyRevision else { return true }
        return queuedRevision > readyRevision
    }

    static func workingNewsRows(queue: [[String: Any]]?, fallback: [[String: Any]],
                                readyRevisions: [String: Int]) -> [[String: Any]] {
        (queue ?? fallback).filter { row in
            let id = row["event_id"] as? String ?? ""
            let revision = (row["revision"] as? NSNumber)?.intValue ??
                Int(row["revision"] as? String ?? "") ?? 0
            return isPending(queuedRevision: revision, readyRevision: readyRevisions[id])
        }
    }

    static func finishedNewsAction(decision: String, originalRevision: Int,
                                   readyRevision: Int?) -> Bool {
        guard ["prepare", "rework"].contains(decision), let readyRevision else { return false }
        let target = originalRevision + (decision == "rework" ? 1 : 0)
        return readyRevision >= target
    }
}
