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

enum TerritoryLevel: String, CaseIterable, Identifiable {
    case country, community, province, city, district, neighborhood
    var id: String { rawValue }
    var title: String {
        switch self {
        case .country: return "Países"
        case .community: return "Comunidades/estados"
        case .province: return "Provincias"
        case .city: return "Municipios"
        case .district: return "Distritos"
        case .neighborhood: return "Barrios"
        }
    }
    func value(_ path: TerritoryRecord) -> String? {
        switch self {
        case .country: return path.country
        case .community: return path.community
        case .province: return path.province
        case .city: return path.city
        case .district: return path.district
        case .neighborhood: return path.neighborhood
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

private struct TerritoryRank: Identifiable {
    var id:String
    var title:String
    var path:[String]
    var seconds:TimeInterval
    var cells:Int
}

struct TerritoryStatsView: View {
    @ObservedObject var model:TimeModel
    @StateObject private var resolver=TerritoryResolver()
    @State private var level:TerritoryLevel = .country
    @State private var breadcrumb:[String]=[]

    private var totals:[String:TimeInterval] {
        model.periodTotals()
    }
    private var pending:Int {
        totals.keys.filter { model.data.territoryCache[$0] == nil }.count
    }
    private var rows:[TerritoryRank] {
        var ranking:[String:TerritoryRank] = [:]
        guard let target=TerritoryLevel.allCases.firstIndex(of:level) else { return [] }
        for (id,seconds) in totals where seconds>0 {
            guard let record=model.data.territoryCache[id] else { continue }
            let levels=Array(TerritoryLevel.allCases.prefix(target+1))
            let names=levels.compactMap { item -> String? in
                guard let value=item.value(record),!value.isEmpty else { return nil }
                return value
            }
            guard names.count==target+1,
                  names.prefix(breadcrumb.count).elementsEqual(breadcrumb) else { continue }
            let key=names.joined(separator:" / ")
            let title=names.last ?? ""
            var entry=ranking[key] ?? TerritoryRank(id:key,title:title,path:names,
                                                     seconds:0,cells:0)
            entry.seconds+=seconds
            entry.cells+=1
            ranking[key]=entry
        }
        return ranking.values.sorted { $0.seconds > $1.seconds }
    }
    private var totalClassified:TimeInterval {
        rows.reduce(0) { $0+$1.seconds }
    }
    private var depth:Int { TerritoryLevel.allCases.firstIndex(of:level) ?? 0 }
    private var maxSeconds:TimeInterval { max(1,rows.first?.seconds ?? 0) }
    private func descend(_ rank:TerritoryRank) {
        guard depth+1<TerritoryLevel.allCases.count else { return }
        breadcrumb=rank.path
        level=TerritoryLevel.allCases[depth+1]
    }
    private func jumpToDepth(_ index:Int) {
        breadcrumb=Array(breadcrumb.prefix(index))
        level=TerritoryLevel.allCases[min(index,TerritoryLevel.allCases.count-1)]
    }

    var body: some View {
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
                    ForEach(TerritoryLevel.allCases) { choice in
                        Button(choice.title) {
                            level=choice
                            breadcrumb=[]
                        }
                        .font(.caption.weight(level == choice ? .bold:.medium))
                        .padding(.horizontal,12).padding(.vertical,8)
                        .foregroundStyle(level == choice ? Color.white : Color.primary)
                        .background(level == choice ? Color.teal :
                            Color(.secondarySystemGroupedBackground),in:Capsule())
                    }
                }
            }
            if !breadcrumb.isEmpty {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:5) {
                        Button("Mundo") { jumpToDepth(0) }
                        ForEach(breadcrumb.indices,id:\.self) { i in
                            Image(systemName:"chevron.right")
                                .font(.caption2).foregroundStyle(.secondary)
                            Button(breadcrumb[i]) {
                                jumpToDepth(i+1)
                            }
                        }
                    }.font(.caption).buttonStyle(.plain).foregroundStyle(.teal)
                }
            }
            HStack(spacing:9) {
                summary(title:"Tiempo clasificado",value:DurationFormat.full(totalClassified))
                summary(title:"Territorios",value:String(rows.count))
            }
            if rows.isEmpty {
                ContentUnavailableView("Sin territorios en este nivel",
                    systemImage:"globe",
                    description:Text("Puede faltar una subdivisión en los datos de Apple, o aún no haber lugares clasificados."))
            } else {
                ForEach(Array(rows.enumerated()),id:\.element.id) { i,rank in
                    Button { descend(rank) } label: {
                        VStack(alignment:.leading,spacing:8) {
                            HStack(alignment:.firstTextBaseline) {
                                Text("\(i+1).").foregroundStyle(.secondary)
                                    .frame(width:24,alignment:.leading)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(rank.title).font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    Text("\(rank.cells) cuadrículas")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength:2)
                                Text(DurationFormat.full(rank.seconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.teal).lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                if depth+1<TerritoryLevel.allCases.count {
                                    Image(systemName:"chevron.right")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            GeometryReader { g in
                                Capsule().fill(Color.teal.opacity(0.10)).overlay(alignment:.leading) {
                                    Capsule().fill(.teal.gradient)
                                        .frame(width:g.size.width*rank.seconds/maxSeconds)
                                }
                            }.frame(height:7)
                        }
                        .padding(13)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in:RoundedRectangle(cornerRadius:16))
                    }.buttonStyle(.plain)
                }
            }
            let missingTime=max(0,TimeAnalytics.sum(totals)-totalClassified)
            if missingTime>0 {
                Label("Sin clasificar en este nivel: \(DurationFormat.full(missingTime))",
                      systemImage:"info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if pending>0 {
                HStack(spacing:7) {
                    Label("\(pending) cuadrículas pendientes",systemImage:"mappin.slash")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(resolver.busy ? "Clasificando" : "Continuar") {
                        Task { await resolver.classify(model,batch:24) }
                    }.font(.caption).disabled(resolver.busy)
                }
            }
            if resolver.hitError { Text(resolver.message).font(.caption2).foregroundStyle(.orange) }
        }
        .padding(.top,6)
        .task {
            // Las antiguas pendientes se clasifican gradualmente; la clasificación
            // de cuadrículas nuevas se pone en cola desde el seguimiento GPS.
            while !Task.isCancelled && pending>0 && !resolver.hitError {
                await resolver.classify(model,batch:8)
                if Task.isCancelled || resolver.hitError { break }
                try? await Task.sleep(for:.seconds(20))
            }
        }
    }
    private func summary(title:String,value:String)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth:.infinity,alignment:.leading)
        .padding(12)
        .background(Color.teal.opacity(0.09),in:RoundedRectangle(cornerRadius:15))
    }
}
