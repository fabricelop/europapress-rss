import Foundation

enum TimeHistoryKind:String {
    case observed = "GPS observado"
    case estimated = "Confirmado manualmente"
    case reconstructed = "Reconstruido"
    case pending = "Sin atribuir"

    static func classify(_ interval:AssignedInterval)->TimeHistoryKind {
        let estimatedSources:Set<String>=[
            "confirmacion_usuario","revision_huecos","recorrido_estimado","descanso"
        ]
        if estimatedSources.contains(interval.source) ||
           interval.quality.contains("asumido") { return .estimated }
        if interval.quality=="observado" { return .observed }
        return .reconstructed
    }
}

struct TimeHistorySlice:Identifiable {
    let start:Date
    let end:Date
    let cell:Cell?
    let kind:TimeHistoryKind
    var seconds:TimeInterval { end.timeIntervalSince(start) }
    var id:String {
        "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)-\(kind.rawValue)"
    }
}

struct TimeDayCoverage {
    let observed:TimeInterval
    let estimated:TimeInterval
    let reconstructed:TimeInterval
    let pending:TimeInterval
    let slices:[TimeHistorySlice]
    let dayDuration:TimeInterval
    var covered:TimeInterval { observed+estimated+reconstructed }
    var coveragePercent:Int {
        guard dayDuration>0 else { return 0 }
        return Int((100*covered/dayDuration).rounded())
    }
}

enum TimeDayCoverageIndex {
    static func build(_ raw:[AssignedInterval],day:Date,
                      calendar:Calendar = .current,
                      now:Date = .now)->TimeDayCoverage {
        let begin=calendar.startOfDay(for:day)
        let nominalFinish=calendar.date(byAdding:.day,value:1,to:begin) ??
            begin.addingTimeInterval(86400)
        // El día de hoy no tiene 24 horas transcurridas todavía.
        let finish=max(begin,min(nominalFinish,now))
        // Canonical normaliza los solapamientos sin duplicar segundos.
        let assigned=TimeAttribution.canonical(raw)
            .compactMap { part -> TimeHistorySlice? in
                let from=max(part.start,begin),to=min(part.end,finish)
                guard to>from else { return nil }
                return TimeHistorySlice(start:from,end:to,cell:part.cell,
                                        kind:TimeHistoryKind.classify(part))
            }.sorted { $0.start<$1.start }
        var slices:[TimeHistorySlice]=[]
        var observed=0.0,estimated=0.0,reconstructed=0.0,pending=0.0
        var position=begin
        for part in assigned {
            if part.start>position {
                let missing=TimeHistorySlice(start:position,end:part.start,
                                              cell:nil,kind:.pending)
                slices.append(missing)
                pending+=missing.seconds
            }
            // Nunca volver hacia atrás ante intervalos históricos solapados.
            let start=max(position,part.start)
            if part.end>start {
                let piece=TimeHistorySlice(start:start,end:part.end,cell:part.cell,
                                            kind:part.kind)
                slices.append(piece)
                switch piece.kind {
                case .observed: observed+=piece.seconds
                case .estimated: estimated+=piece.seconds
                case .reconstructed: reconstructed+=piece.seconds
                case .pending: break
                }
                position=part.end
            }
        }
        if finish>position {
            slices.append(TimeHistorySlice(start:position,end:finish,
                                           cell:nil,kind:.pending))
            pending+=finish.timeIntervalSince(position)
        }
        return TimeDayCoverage(observed:observed,estimated:estimated,
            reconstructed:reconstructed,pending:pending,
            slices:slices,dayDuration:finish.timeIntervalSince(begin))
    }

    /// 96 muestras visuales por día; evita dibujar miles de subtramos SwiftUI.
    static func visualBuckets(_ summary:TimeDayCoverage,
                              count:Int=96)->[TimeHistoryKind] {
        guard summary.dayDuration>0,count>0 else { return [] }
        let start=summary.slices.first?.start ?? .now
        return (0..<count).map { index in
            let begin=start.addingTimeInterval(summary.dayDuration*Double(index)/Double(count))
            let finish=start.addingTimeInterval(summary.dayDuration*Double(index+1)/Double(count))
            var shares:[TimeHistoryKind:Double]=[:]
            for piece in summary.slices where piece.end>begin && piece.start<finish {
                shares[piece.kind,default:0]+=
                    max(0,min(piece.end,finish).timeIntervalSince(max(piece.start,begin)))
            }
            return shares.max(by: { $0.value<$1.value })?.key ?? .pending
        }
    }
}

/// Identifica recuperaciones preexistentes por fuente y continuidad, sin
/// aplicar ningún cambio destructivo a los puntos GPS originales.
struct TimeRecoveryGroup:Identifiable {
    let id:String
    let intervals:[AssignedInterval]
    var start:Date { intervals.first!.start }
    var end:Date { intervals.last!.end }
    var seconds:TimeInterval { intervals.reduce(0){$0+$1.seconds} }
    var source:String { intervals.first!.source }
    var cells:[Cell] {
        var seen:Set<String>=[]
        return intervals.compactMap { seen.insert($0.cell.id).inserted ? $0.cell : nil }
    }
}

enum TimeRecoveryIndex {
    static let sources:Set<String>=[
        "confirmacion_usuario","revision_huecos","recorrido_estimado"
    ]
    static func groups(_ raw:[AssignedInterval])->[TimeRecoveryGroup] {
        let ordered=raw.filter { sources.contains($0.source) }
            .sorted { $0.start<$1.start }
        var groups:[TimeRecoveryGroup]=[]
        var current:[AssignedInterval]=[]
        func finish() {
            guard let first=current.first else { return }
            groups.append(TimeRecoveryGroup(id:first.id.uuidString,
                                            intervals:current))
        }
        for interval in ordered {
            if let previous=current.last,
               (previous.source != interval.source ||
                abs(interval.start.timeIntervalSince(previous.end))>0.05) {
                finish()
                current=[]
            }
            current.append(interval)
        }
        finish()
        return groups.sorted { $0.start>$1.start }
    }
    static func without(_ original:[AssignedInterval],
                        group:TimeRecoveryGroup)->[AssignedInterval] {
        let ids=Set(group.intervals.map(\.id))
        return original.filter { !ids.contains($0.id) }
    }
    static func reassigned(_ group:TimeRecoveryGroup,cell:Cell)->[AssignedInterval] {
        group.intervals.map {
            AssignedInterval(start:$0.start,end:$0.end,cell:cell,
                quality:"asumido · corregido por usuario",
                source:"revision_huecos")
        }
    }
}
