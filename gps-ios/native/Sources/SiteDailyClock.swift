import Foundation

/// Segments of measured GPS time on a civil day's location clock. Empty
/// clock space means "sin datos GPS", NEVER an inferred stay or place.
struct SiteClockSegment: Identifiable {
    let id: String
    let from: Date
    let to: Date
    let stay: SiteGridStay
    let kind: SiteStayPartKind
    let siteID: UUID?
    let manuallyConfirmed: Bool

    var seconds: TimeInterval { max(0, to.timeIntervalSince(from)) }
}

/// Four readable clock bands, aligned to LOCAL 00/06/12/18/24 civil times.
struct SiteClockBand {
    let label: String
    let endLabel: String
    let from: Date
    let to: Date
    let segments: [SiteClockSegment]
}

enum SiteDailyClock {
    static func segments(
        stays: [SiteGridStay],
        partsByStay: [String:[SiteStayPart]],
        on day: Date,
        calendar: Calendar = .current
    ) -> [SiteClockSegment] {
        let window=SiteCalendarDay.interval(for:day,calendar:calendar)
        var segments:[SiteClockSegment]=[]
        for stay in stays where stay.start < window.end && stay.end > window.start {
            let saved=partsByStay[stay.id] ?? []
            let parts=SiteStayHistory.valid(saved,for:stay) ? saved :
                [SiteStayHistory.defaultPart(for:stay,suggested:nil)]
            // Intersect the assigned subperiod WITH ACTUAL GPS fragments.
            // A sampling gap remains uncolored, even if the stay crosses it.
            for fragment in stay.fragments {
                for part in parts {
                    let start=max(window.start,fragment.start,part.from)
                    let end=min(window.end,fragment.end,part.to)
                    guard end>start else { continue }
                    let kind=part.kind == .place && part.siteID == nil ?
                             SiteStayPartKind.unassigned : part.kind
                    let id=stay.id+"|\(Int(start.timeIntervalSince1970*1000))|"+
                           "\(Int(end.timeIntervalSince1970*1000))|\(part.id)"
                    segments.append(SiteClockSegment(
                        id:id,from:start,to:end,stay:stay,kind:kind,
                        siteID:kind == .place ? part.siteID : nil,
                        manuallyConfirmed:kind == .place && part.confirmed))
                }
            }
        }
        return segments.sorted {
            $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from
        }
    }

    static func bands(_ segments: [SiteClockSegment], day: Date,
                      calendar: Calendar = .current) -> [SiteClockBand] {
        let window=SiteCalendarDay.interval(for:day,calendar:calendar)
        let hours=[0,6,12,18]
        let begins=hours.map { hour in
            calendar.date(bySettingHour:hour,minute:0,second:0,of:window.start)
                ?? window.start
        }
        let bounds=begins+[window.end]
        return hours.indices.compactMap { i in
            let begin=bounds[i], end=bounds[i+1]
            guard end>begin else { return nil }
            return SiteClockBand(
                label:String(format:"%02d:00",hours[i]),
                endLabel:String(format:"%02d:00",hours[i]+6),
                from:begin,to:end,
                segments:segments.filter{$0.from<end && $0.to>begin}
            )
        }
    }

    static func totalsBySite(_ segments:[SiteClockSegment]) -> [UUID:TimeInterval] {
        var result:[UUID:TimeInterval]=[:]
        for segment in segments where segment.kind == .place {
            if let id=segment.siteID { result[id,default:0]+=segment.seconds }
        }
        return result
    }
}
