import Foundation

/// Counts entrances into a cell or a named zone without changing GPS history.
/// Consecutive segments inside the same area are one visit; leaving that area
/// and coming back starts a new visit, even if the departure was brief.
enum TimeMapVisitCounter {
    struct Snapshot {
        let count: Int
        let lastInside: Bool
    }

    static func historical(_ intervals: [AssignedInterval],
                           cellIDs: Set<String>,
                           window: DateInterval? = nil) -> Snapshot {
        guard !cellIDs.isEmpty else { return Snapshot(count: 0, lastInside: false) }
        var count = 0
        var wasInside = false
        for segment in TimeAttribution.canonical(intervals) {
            guard segment.end > segment.start else { continue }
            if let window, (segment.end <= window.start || segment.start >= window.end) {
                continue
            }
            let inside = cellIDs.contains(segment.cell.id)
            if inside && !wasInside { count += 1 }
            wasInside = inside
        }
        return Snapshot(count: count, lastInside: wasInside)
    }

    /// Include the current visit immediately, before its first GPS interval
    /// is persisted. Do not double-count if history already ends in the area.
    static func includingCurrent(_ snapshot: Snapshot,
                                 currentCellID: String?,
                                 cellIDs: Set<String>) -> Int {
        let enteringNow = currentCellID.map { cellIDs.contains($0) } ?? false
        return snapshot.count + ((enteringNow && !snapshot.lastInside) ? 1 : 0)
    }
}
