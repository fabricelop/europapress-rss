import SwiftUI

/// Resumen compacto. El detalle por segundos sigue existiendo en el motor
/// del historial, pero no ocupa el calendario con controles de análisis.
struct TimeDayTimeline:View {
    @ObservedObject var model:TimeModel
    let day:Date
    var calendar:Calendar = .current

    private var quality:TimeDayCoverage {
        TimeDayCoverageIndex.build(model.data.intervals,day:day,calendar:calendar)
    }
    private var buckets:[TimeHistoryKind] {
        TimeDayCoverageIndex.visualBuckets(quality,count:48)
    }
    private var gpsSeconds:TimeInterval {
        quality.observed+quality.reconstructed
    }
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text("Registro del día").font(.caption.weight(.medium))
                Spacer()
                Text("\(quality.coveragePercent)% cubierto")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
            }
            HStack(spacing:1) {
                ForEach(Array(buckets.enumerated()),id:\.offset) { _,kind in
                    RoundedRectangle(cornerRadius:1)
                        .fill(tint(kind))
                        .frame(maxWidth:.infinity)
                }
            }
            .frame(height:12)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("Cobertura del día \(quality.coveragePercent) por ciento")
            HStack(spacing:9) {
                legend("GPS",value:gpsSeconds,color:.teal)
                legend("Estimado",value:quality.estimated,color:.orange)
                legend("Sin datos",value:quality.pending,color:.gray)
            }
        }
        .padding(9)
        .background(Color(.secondarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:10))
        .accessibilityIdentifier("gpsDayCompactTimeline")
    }
    private func tint(_ kind:TimeHistoryKind)->Color {
        switch kind {
        case .observed,.reconstructed:return .teal
        case .estimated:return .orange
        case .pending:return .gray.opacity(0.35)
        }
    }
    private func legend(_ name:String,value:TimeInterval,color:Color)->some View {
        HStack(spacing:3) {
            Circle().fill(color).frame(width:6,height:6)
            Text("\(name) \(DurationFormat.small(value))")
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .font(.system(size:10))
        .foregroundStyle(.secondary)
    }
}
