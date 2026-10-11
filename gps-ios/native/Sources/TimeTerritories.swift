import SwiftUI
import CoreLocation

enum RouteDisplayPeriod: String, CaseIterable, Identifiable {
    case lastTrip, today, day, week, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lastTrip: return "Últimas 2 h"
        case .today: return "Hoy"
        case .day: return "24 horas"
        case .week: return "7 días"
        case .all: return "Todo"
        }
    }
}

@MainActor final class TerritoryResolver: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var hitError = false
    @Published private(set) var message = "Pendiente de clasificar"
    private let geocoder = CLGeocoder()

    func classify(_ model: TimeModel, batch: Int = 12) async {
        guard !busy else { return }
        busy = true
        hitError = false
        defer { busy = false }
        let totals=model.confirmedTotals()
        let cells = model.allCells.filter { model.data.territoryCache[$0.id] == nil }
            .sorted { (totals[$0.id] ?? 0) > (totals[$1.id] ?? 0) }
        var successful = 0
        for c in cells.prefix(batch) {
            if Task.isCancelled { break }
            let center = Grid.center(c)
            let position = CLLocation(latitude:center.latitude,longitude:center.longitude)
            do {
                let places = try await geocoder.reverseGeocodeLocation(
                    position, preferredLocale:Locale(identifier:"es_ES"))
                if let p = places.first {
                    let item = TerritoryRecord(country:p.country,
                        community:p.administrativeArea,
                        province:p.subAdministrativeArea,
                        city:p.locality,
                        district:p.subLocality,
                        neighborhood:nil,timeZoneIdentifier:p.timeZone?.identifier)
                    if !item.hierarchy.isEmpty {
                        model.saveTerritory(item,cellIDs:[c.id])
                        successful += 1
                        message = "\(model.data.territoryCache.count) de \(model.allCells.count) clasificadas"
                    }
                }
            } catch {
                hitError = true
                message = "Consultas geográficas pausadas: \(error.localizedDescription)"
                break // no bombardear el servicio de Apple si devuelve límite/error
            }
            try? await Task.sleep(for:.seconds(1.0))
        }
        if successful > 0 { model.save(force:true) }
        if successful == 0 && cells.isEmpty { message="Todo clasificado" }
    }
}

struct TerritoryStatsView:View {
    @ObservedObject var model:TimeModel
    @StateObject private var resolver=TerritoryResolver()
    @State private var level:TerritoryLevel = .country
    @State private var scope:[TerritoryPart]=[]

    private var totals:[String:TimeInterval] { model.periodTotals() }
    private var cache:[String:TerritoryRecord] { model.data.territoryCache }
    private var available:[TerritoryLevel] {
        TerritoryGrouping.availableLevels(cache,totals:totals)
    }
    private var ranked:[TerritoryRank] {
        TerritoryGrouping.rows(totals:totals,cache:cache,level:level,scope:scope)
    }
    private var pending:Int {
        totals.keys.filter { cache[$0] == nil }.count
    }
    private var classifiedSeconds:TimeInterval {
        ranked.reduce(0) { $0+$1.seconds }
    }
    private var incompleteSeconds:TimeInterval {
        TerritoryGrouping.missingLevelSeconds(totals:totals,cache:cache,
                                              level:level,scope:scope)
    }

    private func descend(_ row:TerritoryRank) {
        guard let next=TerritoryGrouping.nextLevel(after:level,scope:row.path,
                       totals:totals,cache:cache) else { return }
        scope=row.path
        level=next
    }
    private func choose(_ next:TerritoryLevel) {
        level=next
        scope=[]
    }
    private func jump(_ index:Int) {
        guard index<scope.count else { return }
        let trail=scope
        level=trail[index].level
        scope=Array(trail.prefix(index))
    }

    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Label("Mi mundo",systemImage:"globe.europe.africa.fill")
                        .font(.title2.bold()).foregroundStyle(.teal)
                    Text("Dónde acumulas más tiempo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if resolver.busy { ProgressView().tint(.teal) }
            }
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:7) {
                    ForEach(available) { choice in
                        Button(choice.title) { choose(choice) }
                            .font(.caption.weight(level == choice ? .bold:.medium))
                            .padding(.horizontal,12).padding(.vertical,8)
                            .foregroundStyle(level == choice ? Color.white : Color.primary)
                            .background(level == choice ? Color.teal :
                                Color(.secondarySystemGroupedBackground),in:Capsule())
                    }
                }
            }
            if !scope.isEmpty {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:5) {
                        Button("Mundo") { choose(.country) }
                        ForEach(Array(scope.enumerated()),id:\.element.id) { i,part in
                            Image(systemName:"chevron.right")
                                .font(.caption2).foregroundStyle(.secondary)
                            Button(part.name) { jump(i) }
                        }
                    }.font(.caption).buttonStyle(.plain).foregroundStyle(.teal)
                }
            }
            HStack(spacing:9) {
                summary(title:"Tiempo en este nivel",
                        value:DurationFormat.full(classifiedSeconds))
                summary(title:level.title,value:String(ranked.count))
            }
            if ranked.isEmpty {
                ContentUnavailableView("Sin datos en este nivel",systemImage:"globe",
                    description:Text("Solo aparecen las divisiones disponibles. Los niveles ausentes no impiden ver las zonas inferiores."))
            } else {
                ForEach(Array(ranked.prefix(100).enumerated()),id:\.element.id) { i,row in
                    Button { descend(row) } label: {
                        VStack(alignment:.leading,spacing:8) {
                            HStack(alignment:.firstTextBaseline) {
                                Text("\(i+1).")
                                    .foregroundStyle(.secondary)
                                    .frame(width:24,alignment:.leading)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(row.title).font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    Text("\(row.cells) cuadrículas")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength:2)
                                Text(DurationFormat.full(row.seconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.teal).lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                if TerritoryGrouping.nextLevel(after:level,scope:row.path,
                                      totals:totals,cache:cache) != nil {
                                    Image(systemName:"chevron.right")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            GeometryReader { g in
                                Capsule().fill(Color.teal.opacity(0.10)).overlay(alignment:.leading) {
                                    Capsule().fill(.teal.gradient)
                                        .frame(width:g.size.width*row.seconds/max(1,ranked.first?.seconds ?? 1))
                                }
                            }.frame(height:7)
                        }
                        .padding(13)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in:RoundedRectangle(cornerRadius:16))
                    }.buttonStyle(.plain)
                }
            }
            if incompleteSeconds>0 {
                Label("Sin dato de \(level.title.lowercased()) para parte del tiempo: \(DurationFormat.full(incompleteSeconds))",
                      systemImage:"info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if pending>0 {
                HStack(spacing:7) {
                    Label("\(pending) cuadrículas sin clasificar",systemImage:"mappin.slash")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(resolver.busy ? "Clasificando" : "Continuar") {
                        Task { await resolver.classify(model,batch:24) }
                    }.font(.caption).disabled(resolver.busy)
                }
            }
            if resolver.hitError {
                Text(resolver.message).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.top,6)
        .task {
            while !Task.isCancelled && pending>0 && !resolver.hitError {
                await resolver.classify(model,batch:8)
                if Task.isCancelled || resolver.hitError { break }
                try? await Task.sleep(for:.seconds(20))
            }
        }
    }

    private func summary(title:String,value:String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(12)
        .background(Color.teal.opacity(0.09),in:RoundedRectangle(cornerRadius:15))
    }
}
