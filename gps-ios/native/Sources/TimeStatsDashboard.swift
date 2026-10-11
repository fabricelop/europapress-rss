import SwiftUI

struct TimeStatsDashboard: View {
    @ObservedObject var model: TimeModel
    private var values: [String:TimeInterval] { model.periodTotals() }
    private var sorted: [(key:String,value:TimeInterval)] {
        Array(values.sorted { $0.value > $1.value }.prefix(40))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("Tu tiempo en el mapa", systemImage: "hourglass")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                        Text(DurationFormat.full(TimeAnalytics.sum(values)))
                            .font(.system(size:30,weight:.bold,design:.rounded))
                            .minimumScaleFactor(0.6).lineLimit(2)
                        Text("Tiempo GPS asignado · \(model.period.title)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(20)
                    .background(LinearGradient(colors:[.teal.opacity(0.18),.cyan.opacity(0.06)],
                                  startPoint:.topLeading,endPoint:.bottomTrailing),
                                in:RoundedRectangle(cornerRadius:22))

                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:8) {
                            ForEach(TimePeriod.allCases) { p in
                                Button(p.title) { model.period = p }
                                    .buttonStyle(.bordered)
                                    .tint(model.period == p ? .teal : .secondary)
                            }
                        }
                    }
                    HStack(spacing:10) {
                        tile("Cuadrículas", value:String(values.count), icon:"square.grid.3x3.fill")
                        tile("Superficie", value:String(format:"%.2f km²",Double(values.count)*0.01), icon:"map.fill")
                    }
                    HStack(spacing:10) {
                        tile("Sin localizar", value:DurationFormat.full(model.data.missingSeconds), icon:"location.slash")
                        tile("Posiciones GPS", value:String(model.data.fixes.count), icon:"location.north.circle")
                    }
                    Text("Superficie aproximada de las cuadrículas visitadas. «Sin localizar» y posiciones GPS corresponden al histórico completo.")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack {
                        Text("Dónde has pasado más tiempo").font(.headline)
                        Spacer()
                        Text("\(sorted.count) de \(values.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    if sorted.isEmpty {
                        ContentUnavailableView("Todavía sin registros", systemImage:"map",
                            description:Text("Activa el GPS en Ajustes para comenzar a acumular tiempo."))
                    }
                    ForEach(Array(sorted.enumerated()), id:\.element.key) { index, entry in
                        VStack(alignment:.leading,spacing:8) {
                            HStack(alignment:.firstTextBaseline) {
                                Text("\(index+1).").foregroundStyle(.secondary).frame(width:25,alignment:.leading)
                                Text(TimeAnalytics.cell(entry.key).map { model.label(for:$0) } ?? entry.key)
                                    .fontWeight(.medium).lineLimit(1)
                                Spacer()
                                Text(DurationFormat.full(entry.value))
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.teal)
                                    .minimumScaleFactor(0.6).lineLimit(1)
                            }
                            GeometryReader { geometry in
                                Capsule().fill(.teal.opacity(0.12))
                                    .overlay(alignment:.leading) {
                                        Capsule().fill(.teal.gradient)
                                            .frame(width:geometry.size.width * entry.value/max(1,sorted.first?.value ?? 1))
                                    }
                            }.frame(height:7)
                        }
                        .padding(13)
                        .background(Color(.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:15))
                    }
                }.padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Estadísticas")
        }
    }
    private func tile(_ label:String,value:String,icon:String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Image(systemName:icon).foregroundStyle(.teal)
            Text(value).font(.system(.title3,design:.rounded,weight:.bold))
                .lineLimit(2).minimumScaleFactor(0.55)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth:.infinity,minHeight:90,alignment:.leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:17))
    }
}
