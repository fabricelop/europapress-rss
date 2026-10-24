import Foundation
import CoreLocation

/// Manage only places that the user explicitly created as "private".
/// GPS fixes, attributed intervals and BIOGRID are never mutated here.
enum SitePrivateManagement {
    static func editable(_ site: IdentifiedSite) -> Bool { site.origin == "private" }

    @discardableResult
    static func update(
        id: UUID, name: String, latitude: Double, longitude: Double,
        sites: inout [IdentifiedSite]
    ) -> Bool {
        guard let index = sites.firstIndex(where: { $0.id == id }),
              editable(sites[index]),
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return false }
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return false }
        let coordinate = CLLocation(latitude:latitude,longitude:longitude)
        // Do not create two distinct site identities with the same name
        // and approximately the same location.
        guard !sites.contains(where: {
            $0.id != id &&
            $0.name.compare(trimmed,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame &&
            CLLocation(latitude:$0.latitude,longitude:$0.longitude).distance(from:coordinate)<60
        }) else { return false }
        sites[index].name = trimmed
        sites[index].latitude = latitude
        sites[index].longitude = longitude
        return true
    }

    /// Deleting a site unlinks all historic assignments without changing
    /// timestamps, grid squares, duration or subperiod boundaries. Every
    /// manual/automatic period previously pointing to this place becomes
    /// "Sin identificar" and can be reclassified later.
    @discardableResult
    static func delete(
        id: UUID,
        sites: inout [IdentifiedSite],
        assignments: inout [SiteStayAssignment],
        parts: inout [SiteStayPart]
    ) -> Bool {
        guard let index=sites.firstIndex(where:{$0.id == id}),
              editable(sites[index]) else { return false }
        sites.remove(at:index)
        assignments.removeAll { $0.siteID == id }
        for index in parts.indices where parts[index].siteID == id {
            parts[index].siteID = nil
            parts[index].kind = .unassigned
            parts[index].confirmed = false
        }
        return true
    }

    static func linkedStays(
        id: UUID, assignments: [SiteStayAssignment],
        parts: [SiteStayPart]
    ) -> Int {
        let legacy=assignments.filter { $0.siteID == id }.map(\.id)
        let edited=parts.filter { $0.siteID == id }.map(\.stayID)
        return Set(legacy+edited).count
    }
}
