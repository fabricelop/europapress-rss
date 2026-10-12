import Foundation

/// Una visita de zona comprende cuadrículas consecutivas de la misma zona.
/// Un salto GPS sin cobertura suficiente interrumpe la visita; no se inventan segundos.
enum TimeZoneVisit {
    static let continuityGap:TimeInterval = 120

    static func beginning(in intervals:[AssignedInterval],
                          zoneIDs:Set<String>,
                          recentCell:Cell,
                          now:Date,
                          fallback:Date,
                          maxSegments:Int = 2_500) -> Date {
        guard zoneIDs.contains(recentCell.id) else { return fallback }
        var start=fallback
        var next=now
        var seen=false
        for interval in intervals.suffix(maxSegments).reversed() {
            guard interval.end<=now else { continue }
            let gap=next.timeIntervalSince(interval.end)
            if gap>continuityGap { break }
            // En cuanto se encuentra un tramo ajeno, la visita terminó allí.
            if !zoneIDs.contains(interval.cell.id) { break }
            start=min(start,interval.start)
            next=interval.start
            seen=true
        }
        return seen ? start : fallback
    }

    static func duration(start:Date?,currentFix:Date?,
                         resting:Bool,now:Date) -> TimeInterval {
        guard let start else { return 0 }
        if resting { return max(0,now.timeIntervalSince(start)) }
        guard let fix=currentFix else { return 0 }
        return max(0,min(now,fix.addingTimeInterval(continuityGap))
            .timeIntervalSince(start))
    }
}
