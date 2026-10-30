import Foundation

struct CellSiteDayPortion:Identifiable {
    let visit:SiteVisitRecord
    let from:Date
    let to:Date
    let seconds:TimeInterval
    var id:String { visit.id + "|" + String(from.timeIntervalSince1970) }
}

struct CellSiteDay:Identifiable {
    let date:Date
    let portions:[CellSiteDayPortion]
    var id:Date { date }
    var seconds:TimeInterval { portions.reduce(0) {$0+$1.seconds} }
}

struct CellSiteRecord: Identifiable {
    let site:IdentifiedSite
    let visits:[SiteVisitRecord]
    let days:[CellSiteDay]
    var id:UUID { site.id }
    var seconds:TimeInterval { visits.reduce(0) {$0+$1.gpsSeconds} }
    var verifiedSeconds:TimeInterval {
        visits.filter(\\.confirmed).reduce(0) {$0+$1.gpsSeconds}
    }
}

/// Read-only, same attribution algorithm as Mis Sitios. Filter the resulting
/// visits by the requested grid square; never infer a site from adjacent cells.
enum CellSiteHistoryIndex {
    static func days(for records:[SiteVisitRecord],
                     calendar:Calendar = .current)->[CellSiteDay] {
        var byDay:[Date:[CellSiteDayPortion]]=[:]
        for record in records {
            var cursor=record.from
            while cursor < record.to {
                guard let window=calendar.dateInterval(of:.day,for:cursor) else { break }
                let end=min(window.end,record.to)
                guard end > cursor else { break }
                let seconds=record.stay.confirmed(from:cursor,to:end)
                if seconds > 0 {
                    byDay[window.start,default:[]].append(
                        CellSiteDayPortion(visit:record,from:cursor,
                                           to:end,seconds:seconds))
                }
                cursor=end
            }
        }
        return byDay.map { date,records in
            CellSiteDay(date:date,portions:records.sorted{$0.from < $1.from})
        }.sorted {$0.date > $1.date}
    }

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
            return CellSiteRecord(site:site,visits:sameGrid,
                                  days:days(for:sameGrid))
        }.sorted {
            $0.seconds == $1.seconds
                ? $0.site.name.localizedStandardCompare($1.site.name) == .orderedAscending
                : $0.seconds > $1.seconds
        }
    }
}
