import Foundation

/// Una visita puede contener varios tramos confirmados, pero nunca suma los
/// huecos sin GPS. Un evento de parada/reanudación puede vincular tramos de
/// la misma cuadrícula sin afirmar que el usuario permaneció durante el corte.
struct TimeVisit: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let confirmedSeconds: TimeInterval
    let fragments: [AssignedInterval]
    let mergedSessions: Int
    let hasTrackingPause: Bool
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var unconfirmedSeconds: TimeInterval { max(0,duration-confirmedSeconds) }
}

enum TimeVisitIndex {
    static let maximumGap: TimeInterval = 180
    static let shortVisualGap: TimeInterval = 60
    static let maximumReconnectedGap: TimeInterval = 12 * 3600
    static let maximumIncidentalOutsideSeconds: TimeInterval = 8

    static func visits(_ raw:[AssignedInterval],cells:Set<String>,
                       fixes:[GPSPoint] = [],
                       powerEvents:[GPSPowerEvent] = [],
                       manualBreaks:[Date] = []) -> [TimeVisit] {
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
                         start:start,end:lastEnd,confirmedSeconds:seconds,
                         fragments:fragments,mergedSessions:1,hasTrackingPause:false))
        }
        // Etapa 1: tramos seguros, separados ante cualquier visita ajena
        // y ante discontinuidades grandes, como en las versiones anteriores.
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
        guard result.count>1 else { return result }

        // Etapa 2: unir presentación y episodio lógico cuando no haya evidencia
        // de salida. Los intervalos originales y los totales quedan intactos.
        let outside=ordered.filter { !cells.contains($0.cell.id) }
        let reliableFixes=fixes.filter { $0.accuracy>=0 && $0.accuracy<=45 }
            .sorted { $0.date<$1.date }
        let events=powerEvents.sorted { $0.date<$1.date }
        let breaks=manualBreaks.sorted()
        var outsideCursor=0
        var fixCursor=0
        var eventCursor=0
        var breakCursor=0
        var joined:[TimeVisit]=[]
        var current=result[0]

        for following in result.dropFirst() {
            let gap=following.start.timeIntervalSince(current.end)
            if gap<0 || gap>maximumReconnectedGap {
                joined.append(current)
                current=following
                continue
            }
            while outsideCursor<outside.count && outside[outsideCursor].end<=current.end {
                outsideCursor+=1
            }
            var escapedSeconds=0.0
            var outsideIndex=outsideCursor
            while outsideIndex<outside.count && outside[outsideIndex].start<following.start {
                let piece=outside[outsideIndex]
                escapedSeconds+=max(0,min(piece.end,following.start)
                    .timeIntervalSince(max(piece.start,current.end)))
                outsideIndex+=1
            }
            while fixCursor<reliableFixes.count &&
                  reliableFixes[fixCursor].date<=current.end {
                fixCursor+=1
            }
            var hasOutsideFix=false
            var nextFix=fixCursor
            while nextFix<reliableFixes.count && reliableFixes[nextFix].date<following.start {
                if !cells.contains(reliableFixes[nextFix].cell.id) {
                    hasOutsideFix=true
                    break
                }
                nextFix+=1
            }
            while breakCursor<breaks.count && breaks[breakCursor]<=current.end {
                breakCursor+=1
            }
            let explicitlySplit=breakCursor<breaks.count &&
                breaks[breakCursor]<following.start

            while eventCursor<events.count && events[eventCursor].date<current.end {
                eventCursor+=1
            }
            var stopped=false
            var resumed=false
            var eventIndex=eventCursor
            while eventIndex<events.count && events[eventIndex].date<=following.start {
                let reason=events[eventIndex].cause
                if reason.contains("Seguimiento detenido") { stopped=true }
                if stopped && reason.contains("Inicio GPS continuo") { resumed=true }
                eventIndex+=1
            }
            // Un salto GPS de segundos a otra casilla puede ser un artefacto.
            // Nunca ignoramos una muestra física verificada fuera de la zona.
            let incidentalOutside=escapedSeconds<=maximumIncidentalOutsideSeconds &&
                                  gap<=shortVisualGap
            let noExit=escapedSeconds==0 || incidentalOutside
            let shortJoin=gap<=shortVisualGap
            let trackedJoin=gap<=maximumGap && escapedSeconds==0
            let pausedJoin=gap>maximumGap && stopped && resumed && escapedSeconds==0
            if !explicitlySplit && !hasOutsideFix && noExit &&
               (shortJoin || trackedJoin || pausedJoin) {
                let interrupted=current.hasTrackingPause || following.hasTrackingPause ||
                    pausedJoin
                current=TimeVisit(id:"\(current.start.timeIntervalSince1970)-\(following.end.timeIntervalSince1970)",
                    start:current.start,end:following.end,
                    confirmedSeconds:current.confirmedSeconds+following.confirmedSeconds,
                    fragments:current.fragments+following.fragments,
                    mergedSessions:current.mergedSessions+following.mergedSessions,
                    hasTrackingPause:interrupted)
            } else {
                joined.append(current)
                current=following
            }
        }
        joined.append(current)
        return joined
    }

    static func portions(_ visits:[TimeVisit],day:Date,
                         calendar:Calendar = .current) -> [(visit:TimeVisit,start:Date,end:Date,seconds:TimeInterval)] {
        let finish=calendar.date(byAdding:.day,value:1,to:day) ?? day.addingTimeInterval(86400)
        return visits.compactMap { visit in
            let begin=max(day,visit.start), end=min(finish,visit.end)
            guard end>begin else { return nil }
            let confirmed=visit.fragments.reduce(0) { total,segment in
                total+max(0,min(finish,segment.end).timeIntervalSince(max(day,segment.start)))
            }
            // Una larga pausa que atraviesa un día no significa que se haya
            // visitado el lugar durante una jornada sin ninguna muestra.
            guard confirmed>0 else { return nil }
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
