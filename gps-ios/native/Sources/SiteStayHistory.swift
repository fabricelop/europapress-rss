import Foundation

/// A continuous residence in ONE 100m grid square. Short GPS sampling
/// gaps are tolerated but never counted as confirmed time.
struct SiteGridStay: Identifiable {
    let cell: Cell
    let start: Date
    let end: Date
    let confirmedSeconds: TimeInterval
    let fragments: [AssignedInterval]
    var id: String { SiteStayPolicy.visitKey(cellID: cell.id, entered: start) }
    var elapsed: TimeInterval { end.timeIntervalSince(start) }

    /// Only the intersection with actually recorded GPS intervals is billed
    /// to a site. Dividing a stay never fabricates missing GPS seconds.
    func confirmed(from: Date, to: Date) -> TimeInterval {
        guard from < to else { return 0 }
        return fragments.reduce(0) { value, item in
            value + max(0, min(to, item.end).timeIntervalSince(max(from, item.start)))
        }
    }
}

enum SiteStayPartKind: String, Codable {
    case place, passing, unassigned
}

struct SiteStayPart: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var stayID: String
    var from: Date
    var to: Date
    var kind: SiteStayPartKind
    var siteID: UUID?
    var confirmed: Bool = false

    var duration: TimeInterval { to.timeIntervalSince(from) }
}

/// Strictly disjoint, complete, ordered partitions, with no hidden time
/// duplication and no changes to the underlying GPS intervals.
enum SiteStayHistory {
    static let minimumSeconds: TimeInterval = 300
    static let maximumSamplingGap: TimeInterval = 120

    static func extract(_ raw: [AssignedInterval]) -> [SiteGridStay] {
        var result: [SiteGridStay] = []
        var pieces: [AssignedInterval] = []
        var active: Cell?
        var lastEnd: Date?
        var total: TimeInterval = 0

        func finish() {
            if let active, let first = pieces.first, let last = pieces.last,
               total > minimumSeconds {
                result.append(SiteGridStay(cell: active, start: first.start,
                         end: last.end, confirmedSeconds: total, fragments: pieces))
            }
            pieces = []
            active = nil
            lastEnd = nil
            total = 0
        }

        for item in TimeAttribution.canonical(raw) where item.end > item.start {
            let gap = item.start.timeIntervalSince(lastEnd ?? item.start)
            if active != nil &&
                (active != item.cell || gap > maximumSamplingGap || gap < -0.001) {
                finish()
            }
            active = item.cell
            pieces.append(item)
            total += item.seconds
            lastEnd = item.end
        }
        finish()
        return result.sorted { $0.start > $1.start }
    }

    static func defaultPart(for stay: SiteGridStay, suggested: UUID?) -> SiteStayPart {
        SiteStayPart(stayID: stay.id, from: stay.start, to: stay.end,
                    kind: suggested == nil ? .unassigned : .place, siteID: suggested)
    }

    static func valid(_ parts: [SiteStayPart], for stay: SiteGridStay) -> Bool {
        guard !parts.isEmpty else { return false }
        let ordered = parts.sorted { $0.from < $1.from }
        guard ordered.first?.from == stay.start, ordered.last?.to == stay.end else { return false }
        for (index, part) in ordered.enumerated() {
            guard part.stayID == stay.id, part.to > part.from else { return false }
            if part.kind == .place && part.siteID == nil { return false }
            if part.kind != .place && part.siteID != nil { return false }
            if index > 0 && ordered[index - 1].to != part.from { return false }
        }
        return true
    }

    static func split(_ parts: [SiteStayPart], partID: UUID,
                      at moment: Date, stay: SiteGridStay) -> [SiteStayPart]? {
        guard valid(parts, for: stay),
              let index = parts.firstIndex(where: { $0.id == partID }),
              moment > parts[index].from.addingTimeInterval(30),
              moment < parts[index].to.addingTimeInterval(-30) else { return nil }
        var updated = parts
        var left = updated[index]
        var right = left
        right.id = UUID()
        left.to = moment
        right.from = moment
        updated.replaceSubrange(index...index, with: [left, right])
        return valid(updated, for: stay) ? updated : nil
    }

    static func mergeWithPrevious(_ parts: [SiteStayPart], partID: UUID,
                                  stay: SiteGridStay) -> [SiteStayPart]? {
        let ordered = parts.sorted { $0.from < $1.from }
        guard valid(ordered, for: stay),
              let index = ordered.firstIndex(where: { $0.id == partID }),
              index > 0 else { return nil }
        var result = ordered
        result[index - 1].to = result[index].to
        result.remove(at: index)
        return valid(result, for: stay) ? result : nil
    }

    static func assignedSeconds(_ parts: [SiteStayPart], for stay: SiteGridStay,
                                siteID: UUID) -> TimeInterval {
        parts.filter { $0.kind == .place && $0.siteID == siteID }
             .reduce(0) { $0 + stay.confirmed(from: $1.from, to: $1.to) }
    }

    /// Only explicit confirmed site partitions count as independent votes.
    /// Repeated fragments of the same site within a stay are one vote.
    static func confirmedSiteCounts(_ parts: [SiteStayPart], stayIDsByCell: [String: String],
                                    cellID: String) -> [UUID: Int] {
        var unique: Set<String> = []
        var result: [UUID: Int] = [:]
        for part in parts where part.kind == .place && part.confirmed {
            guard stayIDsByCell[part.stayID] == cellID, let id = part.siteID else { continue }
            let key = part.stayID + "|" + id.uuidString
            if unique.insert(key).inserted { result[id, default: 0] += 1 }
        }
        return result
    }
}


/// Aggregate real attributed seconds for multiple sites, without assigning
/// any portion of the same GPS interval to two different places.
struct SiteTimeTotal {
    var verifiedVisits = 0
    var verifiedSeconds: TimeInterval = 0
    var suggestedVisits = 0
    var suggestedSeconds: TimeInterval = 0
}

enum SiteStayTotals {
    static func calculate(intervals:[AssignedInterval],
                          parts:[SiteStayPart],
                          assignments:[SiteStayAssignment]) -> [UUID:SiteTimeTotal] {
        let portions=Dictionary(grouping:parts,by:\.stayID)
        let older=Dictionary(uniqueKeysWithValues:assignments.map { ($0.id,$0) })
        var result:[UUID:SiteTimeTotal]=[:]
        for stay in SiteStayHistory.extract(intervals) {
            let explicit=portions[stay.id] ?? []
            var verified:Set<UUID>=[]
            var suggestions:Set<UUID>=[]
            if SiteStayHistory.valid(explicit,for:stay) {
                for part in explicit where part.kind == .place {
                    guard let id=part.siteID else { continue }
                    var current=result[id] ?? SiteTimeTotal()
                    if part.confirmed {
                        current.verifiedSeconds += stay.confirmed(from:part.from,to:part.to)
                        verified.insert(id)
                    } else {
                        current.suggestedSeconds += stay.confirmed(from:part.from,to:part.to)
                        suggestions.insert(id)
                    }
                    result[id]=current
                }
            } else if let legacy=older[stay.id] {
                var current=result[legacy.siteID] ?? SiteTimeTotal()
                if legacy.confirmed {
                    current.verifiedSeconds += stay.confirmedSeconds
                    verified.insert(legacy.siteID)
                } else {
                    current.suggestedSeconds += stay.confirmedSeconds
                    suggestions.insert(legacy.siteID)
                }
                result[legacy.siteID]=current
            }
            for id in verified {
                result[id,default:SiteTimeTotal()].verifiedVisits += 1
            }
            for id in suggestions.subtracting(verified) {
                result[id,default:SiteTimeTotal()].suggestedVisits += 1
            }
        }
        return result
    }
}
