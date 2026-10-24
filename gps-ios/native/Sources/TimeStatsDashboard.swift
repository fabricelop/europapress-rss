import SwiftUI

private enum StatisticsPage: String, CaseIterable, Identifiable {
    case cells = "Cuadrículas", zones = "Zonas"
    var id: String { rawValue }
}
private struct TimeRankEntry:Identifiable {
    var id:String
    var title:String
    var seconds:TimeInterval
    var cellIDs:[String]
    var zoneID:UUID?
}

struct TimeStatsDashboard: View {
    @ObservedObject var model: TimeModel
    @State private var page: StatisticsPage = .cells
    @State private var expandedZones:Set<UUID> = []
    @State private var top = 25
    @State private var onlyIndividualCells = false
    @State private var searchOpen = false
    @State private var searchMapCell: Cell?

    private var values: [String:TimeInterval] {
        model.periodTotals()
    }
    private var ranked:[TimeRankEntry] {
        let zones=model.visibleZones
        let perCell=values
        if onlyIndividualCells {
            let assignedToZones=Set(zones.flatMap(\.cellIDs))
            return perCell.compactMap { id,seconds -> TimeRankEntry? in
                guard seconds>0,!assignedToZones.contains(id),
                      let cell=TimeAnalytics.cell(id) else { return nil }
                return TimeRankEntry(id:"c"+id,title:model.label(for:cell),
                    seconds:seconds,cellIDs:[id],zoneID:nil)
            }.sorted { $0.seconds>$1.seconds }
        }
        let covered=Set(zones.flatMap(\.cellIDs))
        let named=zones.compactMap { zone -> TimeRankEntry? in
            let seconds=zone.cellIDs.reduce(0) { $0+(perCell[$1] ?? 0) }
            guard seconds>0 else { return nil }
            return TimeRankEntry(id:"z"+zone.id.uuidString,title:zone.name,seconds:seconds,
                                 cellIDs:zone.cellIDs,zoneID:zone.id)
        }
        let independent=perCell.compactMap { id,seconds -> TimeRankEntry? in
            guard seconds>0 && !covered.contains(id),
                  let cell=TimeAnalytics.cell(id) else { return nil }
            return TimeRankEntry(id:"c"+id,title:model.label(for:cell),
                    seconds:seconds,cellIDs:[id],zoneID:nil)
        }
        return (named+independent).sorted { $0.seconds>$1.seconds }
    }
    private var displayed:[TimeRankEntry] {
        top>0 ? Array(ranked.prefix(top)) : ranked
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
                        tile("Mis zonas",value:String(model.visibleZones.count),icon:"mappin.and.ellipse")
                        tile("Tiempo asignado",value:DurationFormat.full(TimeAnalytics.sum(values)),icon:"clock")
                    }

                    NavigationLink {
                        GridAverageMapView(model:model)
                    } label: {
                        Label("Analizar medias por cuadrícula",systemImage:"chart.bar.xaxis")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .padding(13)
                            .background(Color.indigo.opacity(0.09),
                                        in:RoundedRectangle(cornerRadius:13))
                    }
                    .foregroundStyle(.indigo)

                    Picker("Vista de estadísticas",selection:$page) {
                        ForEach(StatisticsPage.allCases) { page in Text(page.rawValue).tag(page) }
                    }.pickerStyle(.segmented)

                    switch page {
                    case .cells:
                        cellList
                    case .zones:
                        TimeZonesPanel(model:model)
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
                    }.accessibilityLabel("Buscar zonas y cuadrículas")
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
                Text(onlyIndividualCells ? "Cuadrículas sin Zona" :
                     "Zonas y cuadrículas independientes").font(.headline)
                Spacer()
                Text("\(displayed.count) de \(ranked.count)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Picker("Tipo de listado",selection:$onlyIndividualCells) {
                Text("Todo").tag(false)
                Text("Cuadrículas sin Zona").tag(true)
            }.pickerStyle(.segmented)
            Picker("Mostrar",selection:$top) {
                Text("Top 10").tag(10)
                Text("Top 25").tag(25)
                Text("Top 50").tag(50)
                Text("Todas").tag(-1)
            }.pickerStyle(.segmented)
            if displayed.isEmpty {
                ContentUnavailableView("Sin registros",systemImage:"map",
                    description:Text("Todavía no hay cuadrículas con tiempo registrado."))
            }
            ForEach(Array(displayed.enumerated()),id:\.element.id) { index,item in
                VStack(alignment:.leading,spacing:8) {
                    HStack(spacing:10) {
                        Text("\(index+1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width:23,alignment:.leading)
                        VStack(alignment:.leading,spacing:4) {
                            // El título utiliza todo el ancho disponible y puede
                            // ocupar varias líneas: el icono nunca lo recorta.
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal:false,vertical:true)
                            if item.zoneID != nil {
                                HStack(spacing:5) {
                                    Image(systemName:"square.3.layers.3d")
                                        .foregroundStyle(.teal)
                                        .accessibilityHidden(true)
                                    Text("Zona · \(item.cellIDs.count) cuadrículas")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            } else {
                                Text("Cuadrícula independiente")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth:.infinity,alignment:.leading)
                        Spacer(minLength:4)
                        Text(DurationFormat.full(item.seconds))
                            .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if let zoneID=item.zoneID {
                            Button {
                                if expandedZones.contains(zoneID) { expandedZones.remove(zoneID) }
                                else { expandedZones.insert(zoneID) }
                            } label: {
                                Image(systemName:expandedZones.contains(zoneID) ?
                                      "chevron.up.circle.fill":"chevron.down.circle")
                            }.accessibilityLabel("Desplegar cuadrículas de \(item.title)")
                        }
                    }
                    GeometryReader { geo in
                        Capsule().fill(Color.teal.opacity(0.12)).overlay(alignment:.leading) {
                            Capsule().fill(.teal.gradient).frame(width:
                                geo.size.width*item.seconds/max(1,ranked.first?.seconds ?? 1))
                        }
                    }.frame(height:5)
                    if let zoneID=item.zoneID,expandedZones.contains(zoneID) {
                        ForEach(item.cellIDs,id:\.self) { id in
                            if let cell=TimeAnalytics.cell(id) {
                                Button {
                                    model.navigate(to:cell)
                                } label: {
                                    HStack {
                                        Image(systemName:"square").foregroundStyle(.secondary)
                                        Text("Cuadrícula \(model.data.shortIDs[id] ?? 0)")
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(DurationFormat.full(values[id] ?? 0))
                                            .monospacedDigit().foregroundStyle(.teal)
                                    }.font(.caption)
                                }
                            }
                        }
                    } else if item.zoneID == nil,
                              let cell=item.cellIDs.first.flatMap(TimeAnalytics.cell) {
                        Button("Ver en el mapa") { model.navigate(to:cell) }
                            .font(.caption2)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground),
                            in:RoundedRectangle(cornerRadius:14))
            }
            Text(onlyIndividualCells ?
                "Solo se muestran cuadrículas independientes; se excluyen las de cualquier zona." :
                "Las zonas agrupan cuadrículas completas. Si dos zonas se solapan, pueden compartir tiempo; el total global nunca lo duplica.")
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
