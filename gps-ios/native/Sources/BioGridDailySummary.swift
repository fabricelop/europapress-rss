import SwiftUI

/// Visión rápida: cifras etiquetadas por período y dos hechos calculados.
/// No crea misiones, recompensas ni información editorial artificial.
struct BioGridDailySummary:View {
    let snapshot:BioGridSnapshot
    let lastCycle:BioGridDay?
    let birthsToday:Int64
    let historicalDate:Date?

    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label(historicalDate == nil ? "BIOGRID hoy" :
                    "BIOGRID · \(historicalDate!.formatted(date:.abbreviated,time:.omitted))",
                    systemImage:"sun.max.fill")
                    .font(.headline)
                Spacer()
                if let report = lastCycle {
                    Text("Último ciclo: \(report.date.formatted(date:.abbreviated,time:.omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing:8) {
                metric("Nacidas hoy",birthsToday,"plus.circle")
                metric("Conquistas",lastCycle?.conquests.reduce(0,+) ?? 0,"flag")
                metric("Bajas",lastCycle?.deaths.reduce(0,+) ?? 0,"cross")
                metric("Nuevas",lastCycle?.newCells.reduce(0,+) ?? 0,"square.grid.2x2")
            }
            Text(historicalDate == nil
                ? "Nacimientos de hoy; el resto corresponde al último ciclo completo."
                : "Nacimientos de la fecha histórica; el resto corresponde al ciclo anterior.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(BioGridDailyInsights.headlines(snapshot:snapshot,
                      report:lastCycle).enumerated()),id:\.offset) { item in
                Label {
                    Text(item.element)
                        .font(.subheadline)
                        .fixedSize(horizontal:false,vertical:true)
                } icon: {
                    Image(systemName:"circle.fill")
                        .font(.system(size:7))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.07),
                    in:RoundedRectangle(cornerRadius:12))
    }

    private func metric(_ name:String,_ value:Int64,_ symbol:String)->some View {
        VStack(alignment:.leading,spacing:3) {
            Label(name,systemImage:symbol)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value.formatted())
                .font(.system(.headline,design:.rounded))
                .monospacedDigit()
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }
}
