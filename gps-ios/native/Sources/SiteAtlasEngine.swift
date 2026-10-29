import Foundation

/// Read-only aggregation for the Site Atlas. Uses the SAME attributed GPS
/// seconds as the historical site detail; never estimates missing GPS time.
struct SiteAtlasEntry: Identifiable {
    let siteID: UUID
    let name: String
    var seconds: TimeInterval
    var verifiedSeconds: TimeInterval
    var id: UUID { siteID }
}

struct SiteAtlasDay: Identifiable {
    let date: Date
    let places: [SiteAtlasEntry]
    let seconds: TimeInterval
    var id: Date { date }
}

struct SiteAtlasSnapshot {
    let days: [SiteAtlasDay]
    let globalColorIndexes: [UUID: Int]
}

enum SiteAtlasEngine {
    /// Date splitting is calendar-aware: autumn/winter DST days may have
    /// 23 or 25 hours. Cross-midnight visits count only their observed part.
    static func build(visits: [UUID: [SiteVisitRecord]],
                      sites: [IdentifiedSite],
                      calendar: Calendar = .current) -> SiteAtlasSnapshot {
        let names = Dictionary(uniqueKeysWithValues:sites.map { ($0.id,$0.name) })
        var byDay: [Date: [UUID: (Double,Double)]] = [:]
        var global: [UUID: TimeInterval] = [:]

        for (siteID,records) in visits {
            guard names[siteID] != nil else { continue }
            for visit in records {
                var cursor = visit.from
                while cursor < visit.to {
                    guard let window = calendar.dateInterval(of:.day,for:cursor) else { break }
                    let clippedEnd = min(window.end,visit.to)
                    guard clippedEnd > cursor else { break }
                    let recorded = visit.stay.confirmed(from:cursor,to:clippedEnd)
                    if recorded > 0 {
                        var row = byDay[window.start,default:[:]][siteID] ?? (0,0)
                        row.0 += recorded
                        if visit.confirmed { row.1 += recorded }
                        byDay[window.start,default:[:]][siteID] = row
                        global[siteID,default:0] += recorded
                    }
                    cursor = clippedEnd
                }
            }
        }

        // Colors are stable for the WHOLE atlas, not reassigned each day.
        let ranking = global.sorted {
            $0.value == $1.value
                ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value
        }
        let palette = Dictionary(uniqueKeysWithValues:ranking.enumerated().map {
            ($0.element.key,$0.offset)
        })
        let days: [SiteAtlasDay] = byDay.map { date,values in
            let entries = values.compactMap { siteID,counts -> SiteAtlasEntry? in
                guard let name = names[siteID] else { return nil }
                return SiteAtlasEntry(siteID:siteID,name:name,
                    seconds:counts.0,verifiedSeconds:counts.1)
            }.sorted {
                $0.seconds == $1.seconds
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.seconds > $1.seconds
            }
            return SiteAtlasDay(date:date,places:entries,
                                seconds:entries.reduce(0){$0+$1.seconds})
        }.sorted { $0.date > $1.date }
        return SiteAtlasSnapshot(days:days,globalColorIndexes:palette)
    }

    /// Fast ranking for a *selected* date range from the precomputed day
    /// index, not a new scan of all the historical GPS intervals.
    static func rank(_ days:[SiteAtlasDay])->[SiteAtlasEntry] {
        var merged:[UUID:SiteAtlasEntry]=[:]
        for day in days {
            for place in day.places {
                if var value=merged[place.siteID] {
                    value.seconds += place.seconds
                    value.verifiedSeconds += place.verifiedSeconds
                    merged[place.siteID]=value
                } else { merged[place.siteID]=place }
            }
        }
        return merged.values.sorted {
            $0.seconds == $1.seconds
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.seconds > $1.seconds
        }
    }
}
