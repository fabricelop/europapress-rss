import Foundation

/// Todos los intervalos sin tiempo atribuido. Los extremos provienen del
/// historial canónico, así que no se ofrecen segundos ya contabilizados.
struct TimeGPSGapReview:Identifiable,Equatable {
    let start:Date
    let end:Date
    let previousCell:Cell
    let nextCell:Cell
    let reliableGPSBefore:Bool
    let reliableGPSAfter:Bool
    let contradictoryGPS:Bool
    let trackingWasStopped:Bool

    var id:String {
        let a=Int64((start.timeIntervalSince1970*1000).rounded())
        let b=Int64((end.timeIntervalSince1970*1000).rounded())
        return "\(a):\(b):\(previousCell.id):\(nextCell.id)"
    }
    var seconds:TimeInterval { end.timeIntervalSince(start) }
    var sameCell:Bool { previousCell==nextCell }
    var highConfidence:Bool {
        sameCell && reliableGPSBefore && reliableGPSAfter &&
        !contradictoryGPS && !trackingWasStopped
    }
    var canManuallyAssign:Bool {
        seconds<=86400 && !contradictoryGPS
    }
}

enum TimeGPSGapChoice:Equatable {
    case previous
    case next
    case splitEqually
}

enum TimeGPSGapReviewIndex {
    static let minimumGap:TimeInterval=180

    /// Recorre los intervalos confirmados una sola vez. El "hueco" puede
    /// cruzar zonas, días o pausas: no se atribuye hasta que la persona lo
    /// confirme expresamente.
    static func scan(intervals:[AssignedInterval],fixes:[GPSPoint],
                     events:[GPSPowerEvent],dismissed:Set<String>=[])->[TimeGPSGapReview] {
        let assigned=TimeAttribution.canonical(intervals)
        guard assigned.count>=2 else { return [] }
        let reliable=fixes.filter { $0.accuracy>=0 && $0.accuracy<=45 }
            .sorted { $0.date<$1.date }
        let sortedEvents=events.sorted { $0.date<$1.date }
        var result:[TimeGPSGapReview]=[]
        var fixIndex=0, eventIndex=0
        for i in 1..<assigned.count {
            let before=assigned[i-1]
            let after=assigned[i]
            let seconds=after.start.timeIntervalSince(before.end)
            guard seconds>=minimumGap else { continue }
            while fixIndex<reliable.count && reliable[fixIndex].date<before.end.addingTimeInterval(-180) {
                fixIndex+=1
            }
            var index=fixIndex
            var pre=false
            while index<reliable.count && reliable[index].date<=before.end {
                if before.end.timeIntervalSince(reliable[index].date)<=180 &&
                   reliable[index].cell==before.cell { pre=true }
                index+=1
            }
            var contradictory=false
            while index<reliable.count && reliable[index].date<after.start {
                let point=reliable[index]
                if point.date>before.end &&
                   point.cell != before.cell && point.cell != after.cell {
                    contradictory=true
                }
                index+=1
            }
            var post=false
            var cursor=index
            while cursor<reliable.count &&
                  reliable[cursor].date<=after.start.addingTimeInterval(180) {
                if reliable[cursor].date>=after.start &&
                   reliable[cursor].cell==after.cell { post=true }
                cursor+=1
            }
            while eventIndex<sortedEvents.count && sortedEvents[eventIndex].date<before.end {
                eventIndex+=1
            }
            var e=eventIndex
            var stopped=false
            while e<sortedEvents.count && sortedEvents[e].date<=after.start {
                let cause=sortedEvents[e].cause
                if cause.contains("Seguimiento detenido") ||
                   cause.contains("Pausa voluntaria") { stopped=true }
                e+=1
            }
            let gap=TimeGPSGapReview(start:before.end,end:after.start,
                previousCell:before.cell,nextCell:after.cell,
                reliableGPSBefore:pre,reliableGPSAfter:post,
                contradictoryGPS:contradictory,trackingWasStopped:stopped)
            if !dismissed.contains(gap.id) { result.append(gap) }
        }
        return result.sorted { $0.start>$1.start }
    }

    static func segments(for gap:TimeGPSGapReview,choice:TimeGPSGapChoice)->[AssignedInterval] {
        guard gap.seconds>0 else { return [] }
        func part(_ start:Date,_ end:Date,_ cell:Cell)->AssignedInterval {
            AssignedInterval(start:start,end:end,cell:cell,
                quality:"asumido · confirmado por usuario",
                source:"revision_huecos")
        }
        switch choice {
        case .previous: return [part(gap.start,gap.end,gap.previousCell)]
        case .next: return [part(gap.start,gap.end,gap.nextCell)]
        case .splitEqually:
            guard gap.previousCell != gap.nextCell else {
                return [part(gap.start,gap.end,gap.previousCell)]
            }
            let middle=gap.start.addingTimeInterval(gap.seconds/2)
            return [part(gap.start,middle,gap.previousCell),
                    part(middle,gap.end,gap.nextCell)]
        }
    }
}
