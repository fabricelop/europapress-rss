import SwiftUI

struct TimeCompareView: View {
    @ObservedObject var model: TimeModel
    @State private var aStart = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
    @State private var aEnd = Calendar.current.date(byAdding: .day, value: -8, to: .now) ?? .now
    @State private var bStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var bEnd = Date.now

    private func afterDay(_ day: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
    }
    private var a: [String: TimeInterval] {
        TimeAnalytics.totals(model.data.intervals, from: Calendar.current.startOfDay(for:aStart), to:afterDay(aEnd))
    }
    private var b: [String: TimeInterval] {
        TimeAnalytics.totals(model.data.intervals, from: Calendar.current.startOfDay(for:bStart), to:afterDay(bEnd))
    }
    private var changed: [(key:String,delta:TimeInterval)] {
        let previous = a
        let latest = b
        let keys = Set(previous.keys).union(Set(latest.keys))
        var entries: [(key:String,delta:TimeInterval)] = []
        for key in keys {
            let difference = (latest[key] ?? 0) - (previous[key] ?? 0)
            if abs(difference) > 0.01 {
                entries.append((key:key,delta:difference))
            }
        }
        entries.sort { abs($0.delta) > abs($1.delta) }
        return Array(entries.prefix(50))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Periodo A") {
                    DatePicker("Desde", selection:$aStart, displayedComponents:.date)
                    DatePicker("Hasta", selection:$aEnd, in:aStart..., displayedComponents:.date)
                }
                Section("Periodo B") {
                    DatePicker("Desde", selection:$bStart, displayedComponents:.date)
                    DatePicker("Hasta", selection:$bEnd, in:bStart..., displayedComponents:.date)
                }
                Section("Tiempo asignado") {
                    LabeledContent("Periodo A", value:DurationFormat.full(TimeAnalytics.sum(a)))
                    LabeledContent("Periodo B", value:DurationFormat.full(TimeAnalytics.sum(b)))
                    LabeledContent("Cuadrículas A", value:String(a.count))
                    LabeledContent("Cuadrículas B", value:String(b.count))
                }
                Section("Diferencias por cuadrícula") {
                    if changed.isEmpty {
                        Text("Sin diferencias en los periodos elegidos.").foregroundStyle(.secondary)
                    }
                    ForEach(changed, id: \.key) { entry in
                        HStack {
                            Text(TimeAnalytics.cell(entry.key).map { model.label(for:$0) } ?? entry.key).lineLimit(1)
                            Spacer()
                            Text("\(entry.delta >= 0 ? "+" : "−")\(DurationFormat.full(abs(entry.delta)))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(entry.delta >= 0 ? Color.teal : Color.orange)
                                .minimumScaleFactor(0.7).lineLimit(1)
                        }
                    }
                }
                Section {
                    Text("Compara el tiempo realmente asignado dentro de cada intervalo. La comparación por ciudades, barrios y perímetros libres está pendiente.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Comparar periodos")
        }
    }
}
