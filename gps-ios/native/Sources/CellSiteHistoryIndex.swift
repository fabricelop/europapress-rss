import Foundation

struct CellSiteRecord: Identifiable {
    let site:IdentifiedSite
    let visits:[SiteVisitRecord]
    var id:UUID { site.id }
    var seconds:TimeInterval { visits.reduce(0) {$0+$1.gpsSeconds} }
    var verifiedSeconds:TimeInterval {
        visits.filter(\.confirmed).reduce(0) {$0+$1.gpsSeconds}
    }
}

/// Read-only, same attribution algorithm as Mis Sitios. Filter the resulting
/// visits by the requested grid square; never infer a site from adjacent cells.
enum CellSiteHistoryIndex {
    static func ranked(cell:Cell, intervals:[AssignedInterval],
                       parts:[SiteStayPart],
                       assignments:[SiteStayAssignment],
                       sites:[IdentifiedSite])->[CellSiteRecord] {
        let source=SiteVisitLookup.index(
            intervals:intervals,parts:parts,assignments:assignments,sites:sites)
        let known=Dictionary(uniqueKeysWithValues:sites.map { ($0.id,$0) })
        return source.compactMap { (siteID,all) -> CellSiteRecord? in
            guard let site=known[siteID] else { return nil }
            let sameGrid=all.filter { $0.cell.id == cell.id }
            guard !sameGrid.isEmpty else { return nil }
            return CellSiteRecord(site:site,visits:sameGrid)
        }.sorted {
            $0.seconds == $1.seconds
                ? $0.site.name.localizedStandardCompare($1.site.name) == .orderedAscending
                : $0.seconds > $1.seconds
        }
    }
}
