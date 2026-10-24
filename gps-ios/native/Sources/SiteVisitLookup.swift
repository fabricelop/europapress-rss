import Foundation

/// Read-only index of when every identified place was actually associated
/// with a recorded stay. Works on snapshots; does not write GPS or history.
struct SiteVisitRecord: Identifiable {
    let id: String
    let stay: SiteGridStay
    let from: Date
    let to: Date
    let gpsSeconds: TimeInterval
    let confirmed: Bool

    var cell: Cell { stay.cell }
}

enum SiteVisitLookup {
    static func index(
        intervals: [AssignedInterval],
        parts: [SiteStayPart],
        assignments: [SiteStayAssignment],
        sites: [IdentifiedSite]
    ) -> [UUID: [SiteVisitRecord]] {
        let eligibleIDs=Set(sites.map(\.id))
        let partsByStay=Dictionary(grouping:parts,by:\.stayID)
        let legacyByStay=Dictionary(uniqueKeysWithValues:assignments.map{($0.id,$0)})
        var favoriteByCell:[String:UUID?]=[:]
        var results:[UUID:[SiteVisitRecord]]=[:]

        for stay in SiteStayHistory.extract(intervals) {
            if let manual=partsByStay[stay.id],
               SiteStayHistory.valid(manual,for:stay) {
                for part in manual where part.kind == .place {
                    guard let id=part.siteID,eligibleIDs.contains(id) else { continue }
                    let seconds=stay.confirmed(from:part.from,to:part.to)
                    guard seconds > 0 else { continue }
                    let record=SiteVisitRecord(
                        id:stay.id + "|" + part.id.uuidString,
                        stay:stay,from:part.from,to:part.to,
                        gpsSeconds:seconds,confirmed:part.confirmed)
                    results[id,default:[]].append(record)
                }
                continue
            }

            // The calendar first uses a legacy human confirmation; otherwise
            // it proposes the most confirmed site IN THE SAME GRID SQUARE.
            // A guess coming only from another square must not appear as
            // proof of a visit here.
            let legacy=legacyByStay[stay.id]
            let siteID:UUID?
            let confirmed:Bool
            if let legacy,legacy.confirmed,eligibleIDs.contains(legacy.siteID) {
                siteID=legacy.siteID
                confirmed=true
            } else {
                if let cached=favoriteByCell[stay.cell.id] {
                    siteID=cached
                } else {
                    let best=SiteStayPolicy.rankedSiteIDs(assignments,
                                cellID:stay.cell.id,validIDs:eligibleIDs,
                                parts:parts).first
                    favoriteByCell[stay.cell.id]=best
                    siteID=best
                }
                confirmed=false
            }
            guard let siteID,stay.confirmedSeconds > 0 else { continue }
            results[siteID,default:[]].append(SiteVisitRecord(
                id:stay.id + "|default",
                stay:stay,from:stay.start,to:stay.end,
                gpsSeconds:stay.confirmedSeconds,confirmed:confirmed))
        }

        for key in results.keys {
            results[key]?.sort {
                if $0.from != $1.from { return $0.from < $1.from }
                return $0.to < $1.to
            }
        }
        return results
    }

    static func search(_ sites:[IdentifiedSite],text:String) -> [IdentifiedSite] {
        let term=text.trimmingCharacters(in:.whitespacesAndNewlines)
            .folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
        guard !term.isEmpty else { return sites }
        return sites.filter {
            $0.name.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
                .contains(term)
        }
    }
}
