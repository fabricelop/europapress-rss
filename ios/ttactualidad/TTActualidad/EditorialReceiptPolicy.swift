import Foundation

// Accept only an exact GitHub request receipt for the same editorial episode.
// A network timeout or an absent row is never evidence of execution.
enum EditorialReceiptPolicy {
    static func resolution(project: String, eventID: String, revision: Int,
                           decision: String, requestID: String,
                           receipt: [String: Any]) -> String? {
        guard !requestID.isEmpty, !eventID.isEmpty,
              ["ttittulares", "ttendencias"].contains(project),
              receipt["request_id"] as? String == requestID,
              receipt["project"] as? String == project,
              receipt["event_id"] as? String == eventID,
              receipt["revision"] as? Int == revision,
              receipt["decision"] as? String == decision else { return nil }
        switch (receipt["status"] as? String ?? "").lowercased() {
        case "rejected", "failed": return "Rechazada"
        case "applied", "already_applied":
            return ["prepare", "rework", "hints"].contains(decision)
                ? "En elaboración" : "Confirmada"
        default: return nil
        }
    }
}
