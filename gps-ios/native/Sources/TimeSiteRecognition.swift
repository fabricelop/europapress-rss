import Foundation

/// Independent site identity. No GPS interval or BIOGRID record is modified.
struct IdentifiedSite: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// "private" (user-created) or "apple" (confirmed Apple Maps result).
    var origin: String
}

struct SiteStayAssignment: Codable, Identifiable, Equatable {
    /// A visit is uniquely defined by its grid square and entry timestamp.
    var id: String
    var cellID: String
    var startedAt: Date
    var siteID: UUID
    /// Only explicit human choices count as votes for future automatic choices.
    var confirmed: Bool
}

enum SiteStayDecision: Equatable {
    case tooEarly
    case needsConfirmation
    case skipped
    case identified(UUID, confirmed: Bool)
}

/// Deterministic decisions based on explicit user corrections and GPS stays.
/// Automatic assignments NEVER count as new votes: no feedback loop.
enum SiteStayPolicy {
    static let defaultThresholdMinutes = 15
    static let allowedThresholds = [5, 10, 15, 20, 30, 45, 60]

    static func visitKey(cellID: String, entered: Date) -> String {
        cellID + "|" + String(Int(entered.timeIntervalSince1970))
    }

    static func confirmedCounts(_ assignments: [SiteStayAssignment],
                                cellID: String, parts: [SiteStayPart] = []) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        let overrideKeys = Set(parts.map(\.stayID))
        for assignment in assignments where assignment.cellID == cellID &&
                                             assignment.confirmed &&
                                             !overrideKeys.contains(assignment.id) {
            result[assignment.siteID, default: 0] += 1
        }
        var counted: Set<String> = []
        for part in parts where part.kind == .place && part.confirmed &&
             part.stayID.hasPrefix(cellID + "|") {
            guard let id = part.siteID else { continue }
            let key = part.stayID + "|" + id.uuidString
            if counted.insert(key).inserted { result[id,default:0] += 1 }
        }
        return result
    }

    static func rankedSiteIDs(_ assignments: [SiteStayAssignment],
                              cellID: String,
                              validIDs: Set<UUID>, parts: [SiteStayPart] = []) -> [UUID] {
        let confirmed = assignments.filter {
            $0.cellID == cellID && $0.confirmed && validIDs.contains($0.siteID)
        }
        let counts = confirmedCounts(confirmed, cellID: cellID, parts: parts)
        var newest: [UUID: Date] = [:]
        for vote in confirmed {
            if vote.startedAt > (newest[vote.siteID] ?? .distantPast) {
                newest[vote.siteID] = vote.startedAt
            }
        }
        for part in parts where part.kind == .place &&
             part.stayID.hasPrefix(cellID + "|") {
            guard let id = part.siteID, validIDs.contains(id) else { continue }
            if part.from > (newest[id] ?? .distantPast) { newest[id] = part.from }
        }
        return counts.keys.sorted {
            if counts[$0] != counts[$1] { return counts[$0, default: 0] > counts[$1, default: 0] }
            if newest[$0] != newest[$1] { return newest[$0, default: .distantPast] > newest[$1, default: .distantPast] }
            return $0.uuidString < $1.uuidString
        }
    }

    static func decision(cellID: String, entered: Date, elapsed: TimeInterval,
                         thresholdMinutes: Int,
                         sites: [IdentifiedSite],
                         assignments: [SiteStayAssignment],
                         dismissedKeys: Set<String>,
                         parts: [SiteStayPart] = []) -> SiteStayDecision {
        let key = visitKey(cellID: cellID, entered: entered)
        if let chosen = assignments.first(where: { $0.id == key && $0.cellID == cellID }),
           sites.contains(where: { $0.id == chosen.siteID }) {
            return .identified(chosen.siteID, confirmed: chosen.confirmed)
        }
        guard elapsed >= Double(thresholdMinutes) * 60 else { return .tooEarly }
        if dismissedKeys.contains(key) { return .skipped }
        return rankedSiteIDs(assignments, cellID: cellID,
                             validIDs: Set(sites.map(\.id)), parts: parts).isEmpty
                             ? .needsConfirmation : .tooEarly
    }

    static func automaticChoice(cellID: String, entered: Date,
                                elapsed: TimeInterval, thresholdMinutes: Int,
                                sites: [IdentifiedSite],
                                assignments: [SiteStayAssignment],
                                dismissedKeys: Set<String>,
                                parts: [SiteStayPart] = []) -> UUID? {
        let key = visitKey(cellID: cellID, entered: entered)
        guard elapsed >= Double(thresholdMinutes) * 60,
              !dismissedKeys.contains(key),
              !assignments.contains(where: { $0.id == key }) else { return nil }
        return rankedSiteIDs(assignments, cellID: cellID,
                             validIDs: Set(sites.map(\.id)), parts: parts).first
    }

    /// Selecting a different site on this stay overwrites the automatic guess.
    static func select(siteID: UUID, cellID: String, entered: Date,
                       assignments: [SiteStayAssignment]) -> [SiteStayAssignment] {
        let key = visitKey(cellID: cellID, entered: entered)
        var updated = assignments
        let value = SiteStayAssignment(id: key, cellID: cellID,
                                       startedAt: entered, siteID: siteID,
                                       confirmed: true)
        if let index = updated.firstIndex(where: { $0.id == key }) {
            updated[index] = value
        } else {
            updated.append(value)
        }
        return updated
    }
}
