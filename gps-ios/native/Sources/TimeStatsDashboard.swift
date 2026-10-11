import SwiftUI

private enum StatisticsPage: String, CaseIterable, Identifiable {
    case cells = "Cuadrículas", places = "Lugares", territories = "Territorios"
    var id: String { rawValue }
}
private enum NamedFilter: String, CaseIterable, Identifiable {
    case all = "Todas", named = "Renombradas", unnamed = "Sin renombrar"
    var id: String { rawValue }
}

struct TimeStatsDashboard: View {
    @ObservedObject var model: TimeModel
    @State private var page: StatisticsPage = .cells
    @State private var filter: NamedFilter = .all
    @State private var top = 25
    @State private var searchOpen = false
    @State private var searchMapCell: Cell?

    private var values: [String:TimeInterval] {
        TimeAttribution.byCell(model.data.intervals,
            window:TimeAnalytics.window(for:model.period,now:.now))
    }
    private var filtered: [(key:String,value:TimeInterval)] {
        let base = values.filter { key,value in
            guard value > 0 else { return false }
            switch filter {
            case .all: return true
            case .named: return model.hasCustomName(key)
            case .unnamed: return !model.hasCustomName(key)
            }
        }.sorted { $0.value > $1.value }
        return top > 0 ? Array(base.prefix(top)) : base
    }
    private var matchingCount: Int {
        values.keys.filter { key in
            switch filter {
            case .all: return true
            case .named: return model.hasCustomName(key)
            case .unnamed: return !model.hasCustomName(key)
            }
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    VStack(alignment:.leading,spacing:7) {
                        Label("Tu tiempo en el mapa",systemImage:"hourglass")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.teal)
                        Text(DurationFormat.full(TimeAnalytics.sum(values)))
                            .font(.system(size:29,weight:.bold,design:.rounded))
                            .minimumScaleFactor(0.6).lineLimit(2)
                        Text("Tiempo atribuido sin solapamientos · \(model.period.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(18)
                    .background(LinearGradient(colors:[.teal.opacity(0.18),.cyan.opacity(0.06)],
                                              startPoint:.topLeading,endPoint:.bottomTrailing),
                                in:RoundedRectangle(cornerRadius:20))
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:6) {
                            ForEach(TimePeriod.allCases) { period in
                                Button(period.title) { model.period=period }
                                    .buttonStyle(.bordered)
                                    .tint(model.period == period ? .teal : .secondary)
                            }
                        }
                    }
                    HStack(spacing:9) {
                        tile("Cuadrículas",value:String(values.count),icon:"square.grid.3x3.fill")
                        tile("Superficie aprox.",value:String(format:"%.2f km²",Double(values.count)*0.01),
                             icon:"map")
                    }
                    HStack(spacing:9) {
                        tile("Sin localizar",value:DurationFormat.full(model.data.missingSeconds),icon:"location.slash")
                        tile("Lugares propios",value:String(model.data.places.count),icon:"mappin.and.ellipse")
                    }

                    Picker("Vista de estadísticas",selection:$page) {
                        ForEach(StatisticsPage.allCases) { page in Text(page.rawValue).tag(page) }
                    }.pickerStyle(.segmented)

                    switch page {
                    case .cells:
                        cellList
                    case .places:
                        UserPlacesView(model:model)
                    case .territories:
                        TerritoryStatsView(model:model)
                    }
                }
                .padding(14)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Estadísticas")
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    NavigationLink {
                        TimeQualityView(model:model)
                    } label: {
                        Image(systemName:"checkmark.shield")
                    }.accessibilityLabel("Calidad del historial")
                }
                ToolbarItem(placement:.topBarTrailing) {
                    Button { searchOpen=true } label: {
                        Image(systemName:"magnifyingglass")
                    }.accessibilityLabel("Buscar lugares, cuadrículas y territorios")
                }
            }
            .sheet(isPresented:$searchOpen) {
                TimeUniversalSearch(model:model) { cell in
                    searchMapCell=cell
                    searchOpen=false
                }
            }
            .onChange(of:searchOpen) { _,open in
                if !open,let cell=searchMapCell {
                    searchMapCell=nil
                    model.navigate(to:cell)
                }
            }
        }
    }

    private var cellList: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Dónde has pasado más tiempo").font(.headline)
                Spacer()
                Text("\(filtered.count) de \(matchingCount)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Picker("Mostrar",selection:$top) {
                Text("Top 10").tag(10)
                Text("Top 25").tag(25)
                Text("Top 50").tag(50)
                Text("Todas").tag(-1)
            }.pickerStyle(.segmented)
            Picker("Tipo de cuadrícula",selection:$filter) {
                ForEach(NamedFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }.pickerStyle(.menu)
            if filtered.isEmpty {
                ContentUnavailableView("No hay resultados",systemImage:"square.grid.3x3",
                  description:Text("Cambia el periodo o el filtro de nombres."))
            }
            ForEach(Array(filtered.enumerated()),id:\.element.key) { index,item in
                if let cell=TimeAnalytics.cell(item.key) {
                    HStack(spacing:11) {
                        Text("\(index+1).").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width:25,alignment:.leading)
                        Button {
                            model.navigate(to:cell)
                        } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(model.label(for:cell))
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(DurationFormat.full(item.value))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                                GeometryReader { geo in
                                    Capsule().fill(Color.teal.opacity(0.15))
                                        .overlay(alignment:.leading) {
                                            Capsule().fill(.teal.gradient).frame(width:
                                                geo.size.width * item.value /
                                                max(1,filtered.first?.value ?? 1))
                                        }
                                }.frame(height:5)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Centrar esta cuadrícula en el mapa")
                        NavigationLink {
                            CellHistoryView(model:model,cell:cell)
                        } label: {
                            Image(systemName:"calendar.badge.clock")
                                .font(.title3).foregroundStyle(.teal)
                        }
                        .accessibilityLabel("Ver historial por día")
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground),
                                in:RoundedRectangle(cornerRadius:14))
                }
            }
            Text("Toca el nombre para verla en el mapa; toca el calendario para consultar todas sus visitas.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func tile(_ label:String,value:String,icon:String) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Image(systemName:icon).foregroundStyle(.teal)
            Text(value).font(.system(.title3,design:.rounded,weight:.bold))
                .lineLimit(2).minimumScaleFactor(0.55)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth:.infinity,minHeight:88,alignment:.leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:15))
    }
}
