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
    @Published private(set) var message = "Pendiente de clasificar"
    private let geocoder = CLGeocoder()

    func classify(_ model: TimeModel, batch: Int = 12) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let cells = model.allCells.filter { model.data.territoryCache[$0.id] == nil }
            .sorted { (model.confirmedTotals()[$0.id] ?? 0) > (model.confirmedTotals()[$1.id] ?? 0) }
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
                        neighborhood:nil)
                    if !item.hierarchy.isEmpty {
                        model.saveTerritory(item,cellIDs:[c.id])
                        successful += 1
                        message = "\(model.data.territoryCache.count) de \(model.allCells.count) clasificadas"
                    }
                }
            } catch {
                message = "Consultas geográficas pausadas: \(error.localizedDescription)"
                break // no bombardear el servicio de Apple si devuelve límite/error
            }
            try? await Task.sleep(for:.seconds(1.0))
        }
        if successful > 0 { model.save(force:true) }
        if successful == 0 && cells.isEmpty { message="Todo clasificado" }
    }
}

struct TerritoryStatsView: View {
    @ObservedObject var model: TimeModel
    @StateObject private var resolver = TerritoryResolver()
    @State private var level: TerritoryLevel = .country
    private var totals: [String:TimeInterval] { TimeAttribution.byCell(model.data.intervals,
                              window:TimeAnalytics.window(for:model.period,now:.now)) }
    private var classified: [(name:String,seconds:TimeInterval,cells:Int)] {
        var seconds:[String:TimeInterval] = [:]
        var counts:[String:Int] = [:]
        for (id, duration) in totals where duration > 0 {
            guard let record=model.data.territoryCache[id],
                  let name=level.value(record), !name.isEmpty else { continue }
            // Las zonas homónimas de diferentes provincias no deben confundirse.
            let names=record.hierarchy
            let selected=names.firstIndex(where: { $0.0 == levelName }) ?? (names.count-1)
            let unique=names.prefix(max(0,selected+1)).map(\.1).joined(separator:" / ")
            seconds[unique,default:0] += duration
            counts[unique,default:0] += 1
        }
        return seconds.map { (name:$0.key,seconds:$0.value,cells:counts[$0.key] ?? 0) }
            .sorted { $0.seconds > $1.seconds }
    }
    private var levelName:String {
        switch level {
        case .country:return "País"
        case .community:return "Comunidad/estado"
        case .province:return "Provincia"
        case .city:return "Municipio"
        case .district:return "Distrito"
        case .neighborhood:return "Barrio"
        }
    }
    private var remaining:Int {
        totals.keys.filter { model.data.territoryCache[$0] == nil }.count
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("Nivel territorial",selection:$level) {
                ForEach(TerritoryLevel.allCases) { v in
                    Text(v.title).tag(v)
                }
            }.pickerStyle(.menu)
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("\(totals.count-remaining) de \(totals.count) cuadrículas clasificadas")
                        .font(.caption.weight(.semibold))
                    Text("Clasificación aproximada mediante Apple; puede faltar barrio o distrito.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await resolver.classify(model,batch:24) }
                } label: {
                    if resolver.busy { ProgressView() }
                    else { Label("Continuar 24",systemImage:"mappin.and.ellipse") }
                }
                .buttonStyle(.bordered)
                .disabled(resolver.busy || remaining == 0)
            }
            ProgressView(value:Double(totals.count-remaining),
                         total:Double(max(1,totals.count)))
                .tint(.teal)
            Text("Clasificación progresiva: al abrir esta pantalla se consultan hasta 8 cuadrículas pendientes. Puedes continuar con otras 24. Requiere Internet y envía a Apple el centro de cada cuadrícula consultada; las ya clasificadas quedan guardadas sin conexión.")
                .font(.caption2).foregroundStyle(.secondary)
            if resolver.busy { Text(resolver.message).font(.caption2) }
            if classified.isEmpty {
                ContentUnavailableView("Aún sin territorios",systemImage:"globe.europe.africa",
                  description:Text("Pulsa Clasificar 12 para empezar por las cuadrículas donde más tiempo has pasado."))
            } else {
                ForEach(classified,id:\.name) { row in
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:3) {
                            Text(row.name.replacingOccurrences(of:" / ",with:" › "))
                                .font(.subheadline.weight(.medium))
                            Text("\(row.cells) cuadrículas · solo tiempo ya clasificado")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(DurationFormat.full(row.seconds)).font(.caption.weight(.semibold))
                            .monospacedDigit().foregroundStyle(.teal)
                    }
                    .padding(11).background(Color(.secondarySystemGroupedBackground),
                                             in:RoundedRectangle(cornerRadius:12))
                }
            }
            if remaining > 0 {
                Text("Quedan \(remaining) cuadrículas pendientes. Los territorios todavía sin clasificar no se atribuyen a países o barrios inventados.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.top,5)
        .task {
            if remaining > 0 { await resolver.classify(model,batch:8) }
        }
    }
}
