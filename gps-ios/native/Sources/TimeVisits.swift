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
    static let maximumIncidentalOutsideSeconds: TimeInterval = 30
    static let minimumVisibleSeconds: TimeInterval = 1

    static func visits(_ raw:[AssignedInterval],cells:Set<String>,
                       fixes:[GPSPoint] = [],
                       powerEvents:[GPSPowerEvent] = [],
                       manualBreaks:[Date] = []) -> [TimeVisit] {
        guard !cells.isEmpty else { return [] }
        let canonical=TimeAttribution.canonical(raw)
        // Una separación manual debe funcionar incluso en medio de un tramo
        // continuo de horas; solo se fragmenta la VISTA, nunca el historial.
        let splits=manualBreaks.sorted()
        let ordered:[AssignedInterval]=canonical.flatMap { piece in
            let dates=splits.filter { $0>piece.start && $0<piece.end }
            guard !dates.isEmpty else { return [piece] }
            let borders=[piece.start]+dates+[piece.end]
            return (0..<(borders.count-1)).map { i in
                AssignedInterval(start:borders[i],end:borders[i+1],
                    cell:piece.cell,quality:piece.quality,source:piece.source)
            }
        }
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
            if let lastEnd,
               (piece.start.timeIntervalSince(lastEnd)>maximumGap ||
                manualBreaks.contains(where: { $0>=lastEnd && $0<=piece.start })) {
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
            while breakCursor<breaks.count && breaks[breakCursor]<current.end {
                breakCursor+=1
            }
            let explicitlySplit=breakCursor<breaks.count &&
                breaks[breakCursor]<=following.start

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
            // Microexcursión en una casilla vecina: puede ser un rebote
            // de GPS al bordear la línea. Solo la unimos si ninguna muestra
            // de precisión útil confirma una salida y las casillas vecinas
            // realmente lindan con el punto anterior y posterior.
            let sourceCell=current.fragments.last?.cell
            let targetCell=following.fragments.first?.cell
            let neighborOnly=sourceCell != nil && targetCell != nil &&
                outside[outsideCursor..<outsideIndex].allSatisfy { piece in
                    let cell=piece.cell
                    return abs(cell.row-sourceCell!.row)<=1 &&
                           abs(cell.column-sourceCell!.column)<=1 &&
                           abs(cell.row-targetCell!.row)<=1 &&
                           abs(cell.column-targetCell!.column)<=1
                }
            let incidentalOutside=escapedSeconds>0 &&
                escapedSeconds<=maximumIncidentalOutsideSeconds &&
                gap<=shortVisualGap && neighborOnly
            let noExit=escapedSeconds==0 || incidentalOutside
            let shortJoin=gap<=shortVisualGap
            let trackedJoin=gap<=maximumGap && escapedSeconds==0
            let pausedJoin=gap>maximumGap && stopped && resumed && escapedSeconds==0
            // Hasta 30 min sin asignar puede ser la misma estancia si hay
            // GPS de precisión en AMBOS lados de la misma casilla.
            // Nunca se convierte el vacío en segundos contabilizados.
            var anchoredStay=false
            if gap>maximumGap && gap<=1800 && escapedSeconds==0,
               let oldCell=current.fragments.last?.cell,
               let newCell=following.fragments.first?.cell,
               oldCell==newCell {
                let before=reliableFixes.last(where:{
                    $0.date<=current.end &&
                    current.end.timeIntervalSince($0.date)<=180 &&
                    $0.cell==oldCell
                })
                let after=reliableFixes.first(where:{
                    $0.date>=following.start &&
                    $0.date.timeIntervalSince(following.start)<=180 &&
                    $0.cell==newCell
                })
                if let before,let after {
                    let lat=before.latitude-after.latitude
                    let lon=(before.longitude-after.longitude) *
                        cos(before.latitude * .pi/180)
                    anchoredStay=hypot(lat,lon)*111_200<=max(35,before.accuracy+after.accuracy)
                }
            }
            if !explicitlySplit && !hasOutsideFix && noExit &&
               (shortJoin || trackedJoin || pausedJoin || anchoredStay) {
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

    /// Una muestra inferior a un segundo conserva su tiempo en el historial
    /// pero no se cuenta ni presenta como una visita de "0s".
    static func visible(_ visits:[TimeVisit])->[TimeVisit] {
        visits.filter { $0.confirmedSeconds>=minimumVisibleSeconds }
    }

    struct DetailPeriod:Identifiable {
        let start:Date
        let end:Date
        let seconds:TimeInterval
        var id:Double { start.timeIntervalSince1970 }
    }

    /// Bloques legibles dentro de una visita, sin reescribir intervalos.
    /// Las interrupciones cortas de 15 s no producen docenas de filas.
    static func detailPeriods(_ visit:TimeVisit,from dayStart:Date,to dayEnd:Date,
                              splitAfter:TimeInterval = 15)->[DetailPeriod] {
        let pieces=visit.fragments.compactMap { piece -> DetailPeriod? in
            let start=max(dayStart,piece.start)
            let end=min(dayEnd,piece.end)
            guard end>start else { return nil }
            return DetailPeriod(start:start,end:end,
                                seconds:end.timeIntervalSince(start))
        }.sorted { $0.start<$1.start }
        var result:[DetailPeriod]=[]
        for piece in pieces {
            if let previous=result.last,
               piece.start.timeIntervalSince(previous.end)<=splitAfter {
                result[result.count-1]=DetailPeriod(start:previous.start,
                    end:max(previous.end,piece.end),
                    seconds:previous.seconds+piece.seconds)
            } else {
                result.append(piece)
            }
        }
        return result
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
