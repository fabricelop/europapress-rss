import Foundation

// Single definition of a Buffer reservation that removes a card from Listas.
// Used by both the app's source and the Live Activity refresh extension.
// No publication is inferred from a reservation.
enum LiveListasCountsPolicy {
    private static let hiddenStates: Set<String> = [
        "reserved", "unknown", "pending", "sent"
    ]

    static func key(project: String, id: String, revision: Int) -> String {
        project + ":" + id + ":r" + String(revision)
    }

    static func hiddenKeys(bufferRows: [[String: Any]]) -> Set<String> {
        var result = Set<String>()
        for row in bufferRows {
            guard let project = row["project"] as? String,
                  ["ttittulares", "ttendencias"].contains(project),
                  let id = row["event_id"] as? String, !id.isEmpty
            else { continue }
            let revision = (row["revision"] as? NSNumber)?.intValue ??
                Int(row["revision"] as? String ?? "")
            guard let revision, revision >= 0 else { continue }
            let state = (row["state"] as? String ?? "").lowercased()
            guard hiddenStates.contains(state) else { continue }
            result.insert(key(project: project, id: id, revision: revision))
        }
        return result
    }

    static func visible(project: String, id: String, revision: Int,
                        hidden: Set<String>) -> Bool {
        !hidden.contains(key(project: project, id: id, revision: revision))
    }
}
