import Foundation
import CoreLocation

/// Cross-grid POI reuse. A site can span many 100m squares (a public park,
/// university or shopping centre). Distance to a POI pin is NOT evidence
/// of being inside its footprint: suggested labels remain unconfirmed.
struct SiteSpatialCandidate {
    let siteID: UUID
    let localConfirmations: Int
    let totalConfirmations: Int
    let confirmedCells: Set<String>
    let closestConfirmedCellMeters: CLLocationDistance
    let closestEvidenceMeters: CLLocationDistance
}

enum SiteCrossGridPolicy {
    /// Suggestions may originate from a different square of the same large
    /// named venue. No remote calls and no unverified polygon inference.
    static let publicSuggestionRadius: CLLocationDistance = 1800
    static let privateSuggestionRadius: CLLocationDistance = 180

    private struct Evidence {
        var visits: Set<String> = []
        var cells: Set<String> = []
        var local: [String: Int] = [:]
    }

    static func candidates(for cell: Cell, sites: [IdentifiedSite],
                           assignments: [SiteStayAssignment],
                           parts: [SiteStayPart]) -> [SiteSpatialCandidate] {
        let overwritten = Set(parts.map(\.stayID))
        var bySite: [UUID: Evidence] = [:]
        for a in assignments where a.confirmed && !overwritten.contains(a.id) {
            var entry = bySite[a.siteID] ?? Evidence()
            if entry.visits.insert(a.id).inserted {
                entry.cells.insert(a.cellID)
                entry.local[a.cellID, default: 0] += 1
            }
            bySite[a.siteID] = entry
        }
        for p in parts where p.confirmed && p.kind == .place {
            guard let id = p.siteID, let separator = p.stayID.firstIndex(of: "|") else { continue }
            let cellID = String(p.stayID[..<separator])
            var entry = bySite[id] ?? Evidence()
            if entry.visits.insert(p.stayID).inserted {
                entry.cells.insert(cellID)
                entry.local[cellID, default: 0] += 1
            }
            bySite[id] = entry
        }

        let center = Grid.center(cell)
        let point = CLLocation(latitude: center.latitude, longitude: center.longitude)
        var computed: [SiteSpatialCandidate] = []
        for site in sites {
            guard let entry = bySite[site.id], !entry.visits.isEmpty else { continue }
            let knownCells = entry.cells.compactMap { TimeAnalytics.cell($0) }
            let cellDistances = knownCells.map { known -> CLLocationDistance in
                let position = Grid.center(known)
                return point.distance(from: CLLocation(latitude:position.latitude,
                                                       longitude:position.longitude))
            }
            guard let closestCell = cellDistances.min() else { continue }
            let pinDistance = point.distance(from: CLLocation(
                latitude:site.latitude, longitude:site.longitude))
            let nearest = min(closestCell, pinDistance)
            let radius = site.origin == "private" ? privateSuggestionRadius : publicSuggestionRadius
            let votesHere = entry.local[cell.id, default: 0]
            guard votesHere > 0 || nearest <= radius else { continue }
            computed.append(SiteSpatialCandidate(
                siteID: site.id, localConfirmations: votesHere,
                totalConfirmations: entry.visits.count, confirmedCells: entry.cells,
                closestConfirmedCellMeters: closestCell,
                closestEvidenceMeters: nearest))
        }
        return computed.sorted { a,b in
            // Proven choices in THIS square always take priority.
            if (a.localConfirmations > 0) != (b.localConfirmations > 0) {
                return a.localConfirmations > 0
            }
            if a.localConfirmations != b.localConfirmations {
                return a.localConfirmations > b.localConfirmations
            }
            // With no local votes, reuse confirmed places in adjacent/surrounding
            // squares, ranked by distance before frequency.
            if abs(a.closestEvidenceMeters - b.closestEvidenceMeters) > 85 {
                return a.closestEvidenceMeters < b.closestEvidenceMeters
            }
            if a.totalConfirmations != b.totalConfirmations {
                return a.totalConfirmations > b.totalConfirmations
            }
            return a.siteID.uuidString < b.siteID.uuidString
        }
    }

    /// A different grid can be displayed as a candidate but not selected
    /// automatically. Only an explicit local confirmation enables autofill.
    static func safeAutomaticChoice(_ candidates: [SiteSpatialCandidate]) -> UUID? {
        candidates.first(where: { $0.localConfirmations > 0 })?.siteID
    }

}
