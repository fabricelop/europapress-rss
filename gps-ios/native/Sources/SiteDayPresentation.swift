import Foundation

/// Pure date navigation: always anchored to the civil calendar day, never to
/// the time of an arbitrary DatePicker value. Handles 23/25-hour DST days.
enum SiteCalendarDay {
    static func normalized(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        // Set 12:00 CIVIL time, not "12 elapsed hours since midnight".
        // On autumn DST changeover, the latter becomes 11:00 local.
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
    }

    static func addingDays(_ offset: Int, to date: Date,
                           calendar: Calendar = .current) -> Date {
        let beginning = calendar.startOfDay(for: date)
        let moved = calendar.date(byAdding: .day, value: offset, to: beginning) ?? beginning
        return normalized(moved, calendar: calendar)
    }

    static func interval(for date: Date, calendar: Calendar = .current) -> DateInterval {
        if let result = calendar.dateInterval(of: .day, for: date) { return result }
        let beginning = calendar.startOfDay(for: date)
        return DateInterval(start: beginning,
                            end: calendar.date(byAdding: .day, value: 1, to: beginning)
                            ?? beginning.addingTimeInterval(86400))
    }
}

struct SiteDaySource {
    let stay: SiteGridStay
    var parts: [SiteStayPart]
}

struct SiteDayGroup: Identifiable {
    let id: String
    let siteID: UUID?
    let confirmed: Bool
    var entries: [SiteDaySource]
    var recordedSeconds: TimeInterval

    var firstStart: Date { entries[0].stay.start }
    var lastEnd: Date { entries[entries.count - 1].stay.end }
    var isExpandable: Bool { entries.count > 1 }

    var uniqueCells: Int { Set(entries.map { $0.stay.cell.id }).count }
}

struct SiteDaySiteTotal: Identifiable {
    let id: UUID
    var confirmedSeconds: TimeInterval = 0
    var proposedSeconds: TimeInterval = 0
}

struct SiteDayReport {
    let groups: [SiteDayGroup]
    let siteTotals: [SiteDaySiteTotal]
    let staysCount: Int
    let totalGPS: TimeInterval
    let confirmedGPS: TimeInterval
    let suggestedGPS: TimeInterval
    let passingGPS: TimeInterval
    let unidentifiedGPS: TimeInterval
    /// Distinct historical stays (not map cells) with unclassified recorded
    /// time. A single multi-place stay remains one pending item.
    let pendingStayIDs: Set<String>
    let proposedStayIDs: Set<String>

    /// Classification is NOT the same as manual verification. An untouched,
    /// automatically proposed place counts as classified, but never gets
    /// promoted into an explicit confirmation or a ranking vote.
    var classifiedGPS: TimeInterval { confirmedGPS + suggestedGPS + passingGPS }
    var classifiedFraction: Double {
        guard totalGPS > 0 else { return 0 }
        return min(1, max(0, classifiedGPS / totalGPS))
    }
    var pendingStaysCount: Int { pendingStayIDs.count }
    var proposedStaysCount: Int { proposedStayIDs.count }
    var isFullyClassified: Bool {
        totalGPS > 0 && unidentifiedGPS < 0.1 && pendingStaysCount == 0
    }
    // Compatibility for existing code that references the previous label.
    var reviewedGPS: TimeInterval { classifiedGPS }
    var reviewedFraction: Double { classifiedFraction }
    var isFullyReviewed: Bool { isFullyClassified }
    var confirmedSiteCount: Int {
        siteTotals.filter { $0.confirmedSeconds > 0 }.count
    }
}

/// The outer list merges ONLY consecutive entries for a single common site.
/// Multiple sites within a stay remain independently editable via that row.
/// No GPS samples, decisions or corrections are written by this calculation.
enum SiteDayPresentation {
    static func build(_ entries: [SiteDaySource],
                      on day: Date,
                      calendar: Calendar = .current) -> SiteDayReport {
        let window = SiteCalendarDay.interval(for: day, calendar: calendar)
        let ordered = entries.filter {
            $0.stay.start < window.end && $0.stay.end > window.start
        }.sorted { $0.stay.start < $1.stay.start }

        var groups: [SiteDayGroup] = []
        var bySite: [UUID: SiteDaySiteTotal] = [:]
        var total: TimeInterval = 0
        var confirmed: TimeInterval = 0
        var suggested: TimeInterval = 0
        var passing: TimeInterval = 0
        var unidentified: TimeInterval = 0
        var pendingStays: Set<String> = []
        var proposedStays: Set<String> = []

        for entry in ordered {
            let stay = entry.stay
            let fullParts: [SiteStayPart]
            if SiteStayHistory.valid(entry.parts, for: stay) {
                fullParts = entry.parts.sorted { $0.from < $1.from }
            } else {
                fullParts = [SiteStayHistory.defaultPart(for: stay, suggested: nil)]
            }

            let start = max(window.start, stay.start)
            let end = min(window.end, stay.end)
            guard end > start else { continue }
            let recorded = stay.confirmed(from: start, to: end)
            total += recorded
            var thisStayUnidentified = false
            var thisStayProposed = false

            for part in fullParts {
                let pieceStart = max(start, part.from)
                let pieceEnd = min(end, part.to)
                guard pieceEnd > pieceStart else { continue }
                let seconds = stay.confirmed(from: pieceStart, to: pieceEnd)
                switch part.kind {
                case .place:
                    if let id = part.siteID {
                        var value = bySite[id] ?? SiteDaySiteTotal(id: id)
                        if part.confirmed {
                            confirmed += seconds
                            value.confirmedSeconds += seconds
                        } else {
                            suggested += seconds
                            thisStayProposed = true
                            value.proposedSeconds += seconds
                        }
                        bySite[id] = value
                    } else {
                        unidentified += seconds
                        thisStayUnidentified = true
                    }
                case .passing: passing += seconds
                case .unassigned:
                    unidentified += seconds
                    thisStayUnidentified = true
                }
            }
            if thisStayUnidentified { pendingStays.insert(stay.id) }
            if thisStayProposed { proposedStays.insert(stay.id) }

            // A stay with more than one site is not collapsed with either
            // neighbor; the expandable detail retains its original subperiods.
            let only = fullParts.count == 1 ? fullParts.first : nil
            let site = only?.kind == .place ? only?.siteID : nil
            let isConfirmed = site != nil && (only?.confirmed ?? false)
            let merge = site != nil && groups.last?.siteID == site &&
                        groups.last?.confirmed == isConfirmed
            if merge {
                groups[groups.count - 1].entries.append(entry)
                groups[groups.count - 1].recordedSeconds += recorded
            } else {
                groups.append(SiteDayGroup(id: stay.id, siteID: site,
                                          confirmed: isConfirmed,
                                          entries: [entry],
                                          recordedSeconds: recorded))
            }
        }

        return SiteDayReport(
            groups: groups,
            siteTotals: bySite.values.sorted {
                let left = $0.confirmedSeconds + $0.proposedSeconds
                let right = $1.confirmedSeconds + $1.proposedSeconds
                return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
            },
            staysCount: ordered.count,
            totalGPS: total,
            confirmedGPS: confirmed,
            suggestedGPS: suggested,
            passingGPS: passing,
            unidentifiedGPS: unidentified,
            pendingStayIDs: pendingStays,
            proposedStayIDs: proposedStays)
    }
}
