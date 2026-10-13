import SwiftUI

struct TimeDayTimeline:View {
    @ObservedObject var model:TimeModel
    let day:Date
    var calendar:Calendar = .current
    @State private var selectedFraction=0.5

    private var quality:TimeDayCoverage {
        TimeDayCoverageIndex.build(model.data.intervals,day:day,calendar:calendar)
    }
    private var buckets:[TimeHistoryKind] {
        TimeDayCoverageIndex.visualBuckets(quality)
    }
    private var selectedPoint:TimeHistorySlice? {
        guard let first=quality.slices.first else { return nil }
        let moment=first.start.addingTimeInterval(quality.dayDuration*selectedFraction)
        return quality.slices.first { $0.start<=moment && moment<$0.end }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Label("Línea temporal de 24 h",systemImage:"clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(quality.coveragePercent)% cubierto")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.teal)
            }
            HStack(spacing:1) {
                ForEach(Array(buckets.enumerated()),id:\.offset) { _,type in
                    RoundedRectangle(cornerRadius:1)
                        .fill(tint(type))
                        .frame(maxWidth:.infinity)
                }
            }
            .frame(height:18)
            HStack {
                Text("00:00")
                Spacer()
                Text("06:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("18:00")
                Spacer()
                Text("24:00")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Slider(value:$selectedFraction,in:0...0.999,step:0.002)
                .tint(.teal)
                .accessibilityIdentifier("gpsDayTimelineSlider")
            if let piece=selectedPoint {
                HStack(alignment:.firstTextBaseline) {
                    Text(piece.start.formatted(.dateTime.hour().minute()))
                    Image(systemName:"arrow.right")
                    Text(piece.end.formatted(.dateTime.hour().minute()))
                    Spacer(minLength:4)
                    Text(piece.cell.map { model.label(for:$0) } ?? "Sin GPS")
                        .lineLimit(1)
                }
                .font(.caption.monospacedDigit())
                Text(piece.kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(tint(piece.kind))
            }
            Divider()
            HStack(alignment:.top,spacing:6) {
                qualityItem("Observado",seconds:quality.observed,color:.teal)
                qualityItem("Estimado",seconds:quality.estimated,color:.orange)
                qualityItem("Reconstruido",seconds:quality.reconstructed,color:.blue)
                qualityItem("Pendiente",seconds:quality.pending,color:.gray)
            }
            Text("Los segmentos estimados se muestran separados de los GPS observados. La cobertura del día actual se calcula solo hasta este momento.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in:RoundedRectangle(cornerRadius:12))
    }
    private func tint(_ kind:TimeHistoryKind)->Color {
        switch kind {
        case .observed:return .teal
        case .estimated:return .orange
        case .reconstructed:return .blue
        case .pending:return .gray.opacity(0.4)
        }
    }
    private func qualityItem(_ label:String,seconds:TimeInterval,color:Color)->some View {
        VStack(alignment:.leading,spacing:3) {
            HStack(spacing:3) {
                Circle().fill(color).frame(width:6,height:6)
                Text(label).lineLimit(1).minimumScaleFactor(0.65)
            }
            Text(DurationFormat.small(seconds))
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .font(.system(size:10))
        .frame(maxWidth:.infinity,alignment:.leading)
    }
}
