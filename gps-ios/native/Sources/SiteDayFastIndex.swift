import Foundation

/// An immutable lookup for a complete set of site decisions. Preparing this
/// once avoids scanning the full assignment / subperiod history for EVERY
/// single stay whenever the user advances a calendar day.
struct SiteDayPartsIndex {
    private let byStay: [String:[SiteStayPart]]
    private let confirmedByStay: [String:SiteStayAssignment]
    private let preferredByCell: [String:UUID]

    init(assignments:[SiteStayAssignment],parts:[SiteStayPart],
         sites:[IdentifiedSite]) {
        byStay=Dictionary(grouping:parts,by:\.stayID)
        let valid=Set(sites.map(\.id))
        let overrideIDs=Set(parts.map(\.stayID))
        var legacy:[String:SiteStayAssignment]=[:]
        var countByCell:[String:[UUID:Int]]=[:]
        var lastByCell:[String:[UUID:Date]]=[:]

        for entry in assignments where entry.confirmed && valid.contains(entry.siteID) {
            if legacy[entry.id] == nil { legacy[entry.id]=entry }
            if !overrideIDs.contains(entry.id) {
                countByCell[entry.cellID,default:[:]][entry.siteID,default:0] += 1
            }
            let prev=lastByCell[entry.cellID]?[entry.siteID] ?? .distantPast
            if entry.startedAt > prev {
                lastByCell[entry.cellID,default:[:]][entry.siteID]=entry.startedAt
            }
        }
        confirmedByStay=legacy
        var counted:Set<String>=[]
        for part in parts where part.kind == .place {
            guard let id=part.siteID,valid.contains(id),
                  let divider=part.stayID.lastIndex(of:"|") else { continue }
            let cell=String(part.stayID[..<divider])
            let prev=lastByCell[cell]?[id] ?? .distantPast
            if part.from > prev {
                lastByCell[cell,default:[:]][id]=part.from
            }
            if part.confirmed {
                let key=part.stayID+"|"+id.uuidString
                if counted.insert(key).inserted {
                    countByCell[cell,default:[:]][id,default:0] += 1
                }
            }
        }
        var selected:[String:UUID]=[:]
        for (cell,counts) in countByCell {
            let newest=lastByCell[cell] ?? [:]
            let sorted=counts.keys.sorted { left,right in
                if counts[left] != counts[right] {
                    return counts[left,default:0] > counts[right,default:0]
                }
                if newest[left] != newest[right] {
                    return newest[left,default:.distantPast] >
                           newest[right,default:.distantPast]
                }
                return left.uuidString < right.uuidString
            }
            selected[cell]=sorted.first
        }
        preferredByCell=selected
    }

    func parts(for stay:SiteGridStay)->[SiteStayPart] {
        let explicit=byStay[stay.id] ?? []
        if SiteStayHistory.valid(explicit,for:stay) {
            if explicit.count == 1,let only=explicit.first,
               only.kind == .place && !only.confirmed {
                var proposed=only
                if let best=preferredByCell[stay.cell.id] {
                    proposed.siteID=best
                } else {
                    proposed.siteID=nil
                    proposed.kind = .unassigned
                }
                return [proposed]
            }
            return explicit.sorted{$0.from<$1.from}
        }
        return [SiteStayHistory.defaultPart(
            for:stay,suggested:confirmedByStay[stay.id]?.siteID ??
                preferredByCell[stay.cell.id])]
    }
}

/// Index the GPS stays once by civil day. Intervals crossing midnight appear
/// on BOTH relevant dates and are clipped when presented. No GPS values are
/// persisted or modified.
enum SiteDayIndex {
    static func build(_ stays:[SiteGridStay],
                      calendar:Calendar = .current) -> [Date:[SiteGridStay]] {
        var result:[Date:[SiteGridStay]]=[:]
        for stay in stays {
            var day=calendar.startOfDay(for:stay.start)
            let last=calendar.startOfDay(for:stay.end)
            while day <= last {
                let window=SiteCalendarDay.interval(for:day,calendar:calendar)
                if stay.start < window.end && stay.end > window.start {
                    result[day,default:[]].append(stay)
                }
                guard let next=calendar.date(byAdding:.day,value:1,to:day),
                      next>day else { break }
                day=next
            }
        }
        for key in result.keys {
            result[key]?.sort { $0.start < $1.start }
        }
        return result
    }
}
