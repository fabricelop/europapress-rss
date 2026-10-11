import Foundation

/// Una visita continua agrupa intervalos consecutivos de las cuadrículas del
/// mismo lugar. Cruzar a otra cuadrícula del mismo lugar NO crea otra visita.
struct TimeVisit: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let confirmedSeconds: TimeInterval
    let fragments: [AssignedInterval]
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum TimeVisitIndex {
    static let maximumGap: TimeInterval = 180

    static func visits(_ raw:[AssignedInterval], cells:Set<String>) -> [TimeVisit] {
        guard !cells.isEmpty else { return [] }
        let ordered=TimeAttribution.canonical(raw)
        var result:[TimeVisit]=[]
        var start:Date?
        var lastEnd:Date?
        var seconds:TimeInterval=0
        var fragments:[AssignedInterval]=[]

        func finish() {
            guard let start, let lastEnd, seconds>0 else { return }
            result.append(TimeVisit(id:"\(start.timeIntervalSince1970)-\(lastEnd.timeIntervalSince1970)",
                         start:start,end:lastEnd,confirmedSeconds:seconds,fragments:fragments))
        }
        for piece in ordered {
            let inside=cells.contains(piece.cell.id)
            guard inside else {
                finish()
                start=nil
                lastEnd=nil
                seconds=0
                fragments=[]
                continue
            }
            if let lastEnd, piece.start.timeIntervalSince(lastEnd)>maximumGap {
                finish()
                start=nil
                seconds=0
                fragments=[]
            }
            if start == nil { start=piece.start }
            lastEnd=piece.end
            seconds+=piece.seconds
            fragments.append(piece)
        }
        finish()
        return result
    }

    static func portions(_ visits:[TimeVisit], day:Date,
                         calendar:Calendar = .current) -> [(visit:TimeVisit,start:Date,end:Date,seconds:TimeInterval)] {
        let finish=calendar.date(byAdding:.day,value:1,to:day) ?? day.addingTimeInterval(86400)
        return visits.compactMap { visit in
            let begin=max(day,visit.start), end=min(finish,visit.end)
            guard end>begin else { return nil }
            let confirmed=visit.fragments.reduce(0) { total,segment in
                total+max(0,min(finish,segment.end).timeIntervalSince(max(day,segment.start)))
            }
            return (visit,begin,end,confirmed)
        }
    }

    static func daily(_ visits:[TimeVisit], calendar:Calendar = .current)
        -> [(date:Date,seconds:TimeInterval,visits:Int)] {
        var values:[Date:(TimeInterval,Int)]=[:]
        for visit in visits {
            var date=calendar.startOfDay(for:visit.start)
            while date<visit.end {
                let parts=portions([visit],day:date,calendar:calendar)
                if let p=parts.first {
                    let v=values[date] ?? (0,0)
                    values[date]=(v.0+p.seconds,v.1+1)
                }
                guard let next=calendar.date(byAdding:.day,value:1,to:date),next>date else { break }
                date=next
            }
        }
        return values.map { ($0.key,$0.value.0,$0.value.1) }.sorted { $0.date>$1.date }
    }
}

struct TimeQualitySummary {
    let assigned:TimeInterval
    let observed:TimeInterval
    let reconstructed:TimeInterval
    let overlapSeconds:TimeInterval
    let uncertain:TimeInterval
    var denominator:TimeInterval { max(1,assigned+uncertain) }

    static func calculate(_ raw:[AssignedInterval], missing:TimeInterval) -> Self {
        let complete=max(0,raw.reduce(0) { $0+max(0,$1.seconds) })
        let normalized=TimeAttribution.canonical(raw)
        let observed=normalized.filter { $0.quality == "observado" }.reduce(0) { $0+$1.seconds }
        let reconstructed=normalized.filter { $0.quality != "observado" }.reduce(0) { $0+$1.seconds }
        let total=observed+reconstructed
        return Self(assigned:total,observed:observed,reconstructed:reconstructed,
                    overlapSeconds:max(0,complete-total),uncertain:max(0,missing))
    }
}
