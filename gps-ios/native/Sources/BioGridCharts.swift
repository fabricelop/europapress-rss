import SwiftUI
import Charts

private enum BioGridChartMetric: String, CaseIterable, Identifiable {
    case population = "Población", territory = "Territorio"
    var id:String { rawValue }
}

private enum BioGridChartRange: String, CaseIterable, Identifiable {
    case week = "7 días", month = "30 días", quarter = "90 días",
         year = "1 año", all = "Todo"
    var id:String { rawValue }
    var days:Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        case .all: return nil
        }
    }
}

private struct BioGridChartLine: Identifiable {
    let date:Date
    let family:Int
    let value:Double
    var id:String { "\(Int(date.timeIntervalSince1970)):\(family)" }
}

/// Gráfica comparativa sin red ni IA. Cada punto corresponde a un cierre
/// histórico de BIOGRID, no a datos reconstruidos de una fuente externa.
struct BioGridChartsView:View {
    let history:[BioGridHistoryPoint]
    let colors:[Color]
    let onGoToDate:(Date)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var metric:BioGridChartMetric = .population
    @State private var range:BioGridChartRange = .month
    @State private var visible:Set<Int> = Set(0..<7)
    @State private var selectedDate:Date?

    private var chosen:[BioGridHistoryPoint] {
        guard let last = history.last else { return [] }
        guard let days = range.days else { return history }
        let limit = BioGridController.madrid.date(byAdding:.day,
            value:-(days-1),to:last.date) ?? last.date
        return history.filter { $0.date >= limit }
    }

    private var lines:[BioGridChartLine] {
        chosen.flatMap { point -> [BioGridChartLine] in
            visible.sorted().map { family in
                BioGridChartLine(date:point.date,family:family,
                    value:metric == .population
                        ? Double(point.population[family])
                        : Double(point.territory[family]))
            }
        }
    }

    private var selectionValues:[Int64] {
        guard let current = chosen.last else { return Array(repeating:0,count:7) }
        return metric == .population ? current.population : current.territory.map(Int64.init)
    }

    private var initialValues:[Int64] {
        guard let original = chosen.first else { return Array(repeating:0,count:7) }
        return metric == .population ? original.population : original.territory.map(Int64.init)
    }

    private var story:String {
        guard !chosen.isEmpty else { return "Sin evolución disponible" }
        let values = selectionValues
        let leader = (0..<7).max { values[$0] < values[$1] } ?? 0
        let growth = (0..<7).max {
            (values[$0]-initialValues[$0]) < (values[$1]-initialValues[$1])
        } ?? 0
        return "\(BioGridEngine.letters[leader]) lidera con \(values[leader].formatted()) \(metric == .population ? "bacterias" : "cuadrículas"). \(BioGridEngine.letters[growth]) es la familia que más ha crecido en este período."
    }

    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    Text("Historia de las siete familias")
                        .font(.headline)
                    Text(story)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                    Picker("Qué comparar",selection:$metric) {
                        ForEach(BioGridChartMetric.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }.pickerStyle(.segmented)
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:7) {
                            ForEach(BioGridChartRange.allCases) { value in
                                Button(value.rawValue) { range = value }
                                    .buttonStyle(.bordered)
                                    .tint(range == value ? .indigo : .secondary)
                            }
                        }
                    }
                    familySelection
                    if lines.isEmpty {
                        ContentUnavailableView("Sin datos",systemImage:"chart.xyaxis.line",
                            description:Text("Activa al menos una familia para ver su evolución."))
                    } else {
                        Chart(lines) { item in
                            LineMark(
                                x:.value("Fecha",item.date),
                                y:.value(metric.rawValue,item.value),
                                series:.value("Familia",BioGridEngine.letters[item.family])
                            )
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(colors[item.family])
                            .lineStyle(StrokeStyle(lineWidth:2.2))
                        }
                        .chartLegend(.hidden)
                        .chartXSelection(value:$selectedDate)
                        .frame(height:250)
                        .padding(.vertical,4)
                        Text("Una línea por familia: su color se mantiene siempre. Eje horizontal: fechas; eje vertical: \(metric == .population ? "bacterias" : "cuadrículas dominadas").")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let selectedDate {
                        HStack {
                            Label(selectedDate.formatted(date:.abbreviated,time:.omitted),
                                systemImage:"calendar")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Button("Ver en el mapa") {
                                onGoToDate(selectedDate)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if !chosen.isEmpty {
                        VStack(alignment:.leading,spacing:9) {
                            Text("Valores al final del período").font(.headline)
                            ForEach(0..<7,id:\.self) { family in
                                HStack(spacing:9) {
                                    Text(BioGridEngine.letters[family]).bold()
                                        .frame(width:26,height:26)
                                        .background(colors[family],
                                                    in:RoundedRectangle(cornerRadius:5))
                                        .foregroundStyle(.black)
                                    Text(selectionValues[family].formatted())
                                        .monospacedDigit()
                                    Spacer()
                                    let diff = selectionValues[family]-initialValues[family]
                                    Text("\(diff >= 0 ? "+" : "")\(diff.formatted())")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(diff > 0 ? Color.green :
                                            diff < 0 ? Color.red : Color.secondary)
                                }
                            }
                            Text("La variación compara el primer y último día del período seleccionado.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in:RoundedRectangle(cornerRadius:12))
                    }
                    Text("Sin agrupación de cuadrículas. Datos calculados en el iPhone a partir del tiempo GPS.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationTitle("Evolución BIOGRID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    private var familySelection:some View {
        HStack(spacing:5) {
            ForEach(0..<7,id:\.self) { family in
                Button {
                    if visible.contains(family) { visible.remove(family) }
                    else { visible.insert(family) }
                } label: {
                    Text(BioGridEngine.letters[family])
                        .font(.caption.bold())
                        .frame(maxWidth:.infinity)
                        .frame(height:32)
                        .background(visible.contains(family)
                            ? colors[family] : Color(.systemGray5),
                            in:RoundedRectangle(cornerRadius:7))
                        .foregroundStyle(visible.contains(family) ? .black : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(visible.contains(family) ? "Ocultar" : "Mostrar") familia \(BioGridEngine.letters[family])")
            }
        }
    }
}

struct BioGridCellChartView:View {
    let cell:Cell
    let history:[BioGridCellPoint]
    let colors:[Color]
    @State private var range:BioGridChartRange = .month
    @State private var visible:Set<Int> = Set(0..<7)
    @Environment(\.dismiss) private var dismiss

    private var points:[BioGridChartLine] {
        guard let last = history.last else { return [] }
        let limit = range.days.flatMap { BioGridController.madrid.date(
            byAdding:.day,value:-($0-1),to:last.date) } ?? .distantPast
        // Conservar el estado inicial anterior al período permite que
        // las curvas escalonadas arranquen con el valor real.
        let ordered = history.filter { $0.date >= limit }
        let baseline = history.last(where: { $0.date < limit })
        let window = (baseline.map { [$0] } ?? []) + ordered
        return window.flatMap { point in
            visible.sorted().map { family in
                BioGridChartLine(date:point.date,family:family,
                    value:Double(point.counts[family]))
            }
        }
    }

    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text("Poblaciones en \(cell.id)")
                        .font(.headline)
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack {
                            ForEach(BioGridChartRange.allCases) { value in
                                Button(value.rawValue) { range = value }
                                    .buttonStyle(.bordered)
                                    .tint(range == value ? .indigo : .secondary)
                            }
                        }
                    }
                    HStack(spacing:6) {
                        ForEach(0..<7,id:\.self) { i in
                            Button {
                                if visible.contains(i) { visible.remove(i) }
                                else { visible.insert(i) }
                            } label: {
                                Text(BioGridEngine.letters[i]).font(.caption.bold())
                                    .frame(maxWidth:.infinity).frame(height:32)
                                    .background(visible.contains(i) ? colors[i] :
                                        Color(.systemGray5),in:RoundedRectangle(cornerRadius:6))
                                    .foregroundStyle(visible.contains(i) ? .black : .secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    if points.isEmpty {
                        ContentUnavailableView("Sin datos históricos",systemImage:"chart.xyaxis.line",
                            description:Text("Todavía no hay cambios registrados para este período."))
                    } else {
                        Chart(points) { point in
                            LineMark(x:.value("Fecha",point.date),
                                     y:.value("Bacterias",point.value),
                                     series:.value("Familia",BioGridEngine.letters[point.family]))
                                .interpolationMethod(.stepEnd)
                                .foregroundStyle(colors[point.family])
                                .lineStyle(StrokeStyle(lineWidth:2))
                        }
                        .chartLegend(.hidden)
                        .frame(height:260)
                    }
                    Text("Cada línea indica los individuos de una familia dentro de esta cuadrícula, sin agregarlos con otras.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }
            .navigationTitle("Historia de cuadrícula")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}

struct BioGridEventsSheet:View {
    let events:[BioGridTerritoryEvent]
    let colors:[Color]
    let placeName:(String)->String
    let populationAfter:(BioGridTerritoryEvent)->Int64
    let onLocate:(Cell)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind:BioGridTerritoryEvent.Kind? = nil

    private var filtered:[BioGridTerritoryEvent] {
        events.filter { kind == nil || $0.kind == kind }
            .sorted { $0.cellKey < $1.cellKey }
    }

    private func locate(_ key:String) {
        let parts = key.split(separator:":")
        guard parts.count == 2,
              let row = Int(parts[0]),let col = Int(parts[1]) else { return }
        onLocate(Cell(row:row,column:col))
        dismiss()
    }

    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:7) {
                        filterButton("Todas",value:nil)
                        filterButton("Conquistas",value:.conquest)
                        filterButton("Primeras",value:.first)
                        filterButton("Recolonizadas",value:.recolonization)
                    }.padding(12)
                }
                HStack {
                    Text("\(events.filter { $0.kind == .conquest }.count) conquistas · \(events.filter { $0.kind == .first }.count) primeras colonizaciones")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal,16).padding(.bottom,7)
                if filtered.isEmpty {
                    ContentUnavailableView("Sin cambios de este tipo",
                        systemImage:"flag",
                        description:Text("La última jornada completa no registró estos acontecimientos."))
                } else {
                    List(filtered) { event in
                        Button { locate(event.cellKey) } label: {
                            HStack(alignment:.top,spacing:12) {
                                Image(systemName:event.kind == .conquest ? "flag.fill" :
                                     event.kind == .recolonization ? "circle.dotted" : "circle.fill")
                                    .foregroundStyle(colors[event.family])
                                    .frame(width:25)
                                    .padding(.top,3)
                                VStack(alignment:.leading,spacing:5) {
                                    Text(event.kind == .conquest ? "Conquista" :
                                         event.kind == .first ? "Primera colonización" :
                                         "Recolonización")
                                        .font(.headline)
                                    Text(placeName(event.cellKey))
                                        .font(.subheadline.weight(.medium))
                                        .fixedSize(horizontal:false,vertical:true)
                                    HStack(spacing:7) {
                                        if let previous = event.previousFamily {
                                            Text(BioGridEngine.letters[previous])
                                                .foregroundStyle(colors[previous]).bold()
                                            Image(systemName:"arrow.right")
                                        }
                                        Text("Familia \(BioGridEngine.letters[event.family])")
                                            .foregroundStyle(colors[event.family]).bold()
                                    }.font(.caption)
                                    Text("\(populationAfter(event).formatted()) bacterias de la familia \(BioGridEngine.letters[event.family]) al cierre del ciclo")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength:0)
                                Image(systemName:"scope").foregroundStyle(.indigo)
                            }.padding(.vertical,6)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Cambios territoriales")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    private func filterButton(_ title:String,value:BioGridTerritoryEvent.Kind?) -> some View {
        Button(title) { kind = value }
            .buttonStyle(.bordered)
            .tint(kind == value ? .indigo : .secondary)
    }
}