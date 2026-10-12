import SwiftUI
import Foundation

/// Funciones de consulta: no modifican las posiciones ni los intervalos originales.
struct TimeDiscoveryHome:View {
    @ObservedObject var model:TimeModel
    var body:some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TimeWhereWasIView(model:model)
                    } label: {
                        Label {
                            VStack(alignment:.leading,spacing:4) {
                                Text("¿Dónde estaba?").font(.headline)
                                Text("Busca un período con fecha y hora de comienzo y final.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName:"calendar.badge.clock").foregroundStyle(.teal) }
                    }
                    NavigationLink {
                        TimeGeoPassportView(model:model)
                    } label: {
                        Label {
                            VStack(alignment:.leading,spacing:4) {
                                Text("Pasaporte geográfico").font(.headline)
                                Text("Países, regiones y ciudades que has visitado.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName:"globe.europe.africa.fill").foregroundStyle(.teal) }
                    }
                    NavigationLink {
                        TimeAchievementsView(model:model)
                    } label: {
                        Label {
                            VStack(alignment:.leading,spacing:4) {
                                Text("Hitos de exploración").font(.headline)
                                Text("Tus descubrimientos y próximos objetivos.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName:"rosette").foregroundStyle(.teal) }
                    }
                } header: {
                    Text("Descubrimientos")
                }
                Section {
                    NavigationLink {
                        TimeGeoAlertsSettings(model:model)
                    } label: {
                        Label {
                            VStack(alignment:.leading,spacing:4) {
                                Text("Avisos geográficos personales").font(.headline)
                                Text("Entrada en zona, estancia y primera ciudad.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName:"bell.badge").foregroundStyle(.teal) }
                    }
                } footer: {
                    Text("Los avisos dependen de las ubicaciones que iOS entregue. No se garantiza la detección inmediata con la aplicación suspendida.")
                }
            }
            .navigationTitle("Descubrir")
        }
    }
}

struct TimeFoundSlice:Identifiable {
    let cell:Cell
    let start:Date
    let end:Date
    let quality:String
    var id:String { cell.id+"|"+String(start.timeIntervalSince1970)+"|"+String(end.timeIntervalSince1970) }
    var seconds:TimeInterval { end.timeIntervalSince(start) }
}

enum TimeWhereWasIIndex {
    static func slices(_ raw:[AssignedInterval],from:Date,to:Date)->[TimeFoundSlice] {
        guard from<to else { return [] }
        return TimeAttribution.canonical(raw).compactMap { piece in
            let a=max(from,piece.start), b=min(to,piece.end)
            guard a<b else { return nil }
            return TimeFoundSlice(cell:piece.cell,start:a,end:b,quality:piece.quality)
        }
    }
    static func totals(_ slices:[TimeFoundSlice])->[(String,TimeInterval)] {
        var result:[String:TimeInterval]=[:]
        for s in slices { result[s.cell.id,default:0]+=s.seconds }
        return result.sorted { $0.value>$1.value }
    }
}

struct TimeWhereWasIView:View {
    @ObservedObject var model:TimeModel
    @State private var from=Calendar.current.date(byAdding:.day,value:-1,to:.now) ?? .now
    @State private var to=Date()
    private var matches:[TimeFoundSlice] {
        TimeWhereWasIIndex.slices(model.data.intervals,from:from,to:to)
    }
    var body:some View {
        List {
            Section("Período de búsqueda") {
                DatePicker("Comienzo",selection:$from,displayedComponents:[.date,.hourAndMinute])
                DatePicker("Final",selection:$to,displayedComponents:[.date,.hourAndMinute])
                if to<=from {
                    Label("El final debe ser posterior al comienzo.",systemImage:"exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent("Duración solicitada",value:DurationFormat.full(to.timeIntervalSince(from)))
                }
            }
            if from<to {
                let slices=matches
                let ranks=TimeWhereWasIIndex.totals(slices)
                let total=slices.reduce(0) { $0+$1.seconds }
                Section("Resultado") {
                    LabeledContent("Tiempo localizado",value:DurationFormat.full(total))
                    LabeledContent("Cuadrículas",value:String(ranks.count))
                    if total+1<to.timeIntervalSince(from) {
                        Text("Parte del período no tiene una ubicación atribuible. No se inventan posiciones para rellenar huecos.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if ranks.isEmpty {
                        ContentUnavailableView("Sin datos en ese período",systemImage:"location.slash",
                            description:Text("Prueba otro intervalo o consulta el historial GPS."))
                    }
                }
                if !ranks.isEmpty {
                    Section("Lugares del período · más tiempo primero") {
                        ForEach(Array(ranks.prefix(100)),id:\.0) { item in
                            if let cell=TimeAnalytics.cell(item.0) {
                                NavigationLink {
                                    CellHistoryView(model:model,cell:cell)
                                } label: {
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(model.primaryZone(for:cell)?.name ?? model.label(for:cell))
                                            .font(.subheadline.weight(.semibold))
                                        Text("Cuadrícula \(model.data.shortIDs[cell.id] ?? 0)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(DurationFormat.full(item.1))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                                    }
                                }
                            }
                        }
                    }
                    Section("Cronología · comienzo a final") {
                        ForEach(Array(slices.prefix(160))) { item in
                            VStack(alignment:.leading,spacing:4) {
                                Text(model.primaryZone(for:item.cell)?.name ?? model.label(for:item.cell))
                                    .font(.subheadline.weight(.semibold))
                                Text(item.start.formatted(date:.abbreviated,time:.shortened) + " – " + item.end.formatted(date:.abbreviated,time:.shortened))
                                    .font(.caption.monospacedDigit())
                                HStack {
                                    Text(DurationFormat.full(item.seconds))
                                    Spacer()
                                    Text(item.quality == "observado" ? "Entre muestras GPS" : "Trayecto interpolado")
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if slices.count>160 {
                            Text("Mostrados los primeros 160 tramos de \(slices.count). Reduce el período para ver el resto.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("¿Dónde estaba?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GeoPassportRow:Identifiable {
    let id:String
    let name:String
    let timeZoneIdentifier:String?
    var seconds:TimeInterval
    var first:Date
    var last:Date
    var calendarDays:Set<String>
    var days:Int { calendarDays.count }
}

enum GeoPassportIndex {
    static func rows(_ raw:[AssignedInterval],cache:[String:TerritoryRecord],
                     level:TerritoryLevel)->[GeoPassportRow] {
        var grouped:[String:GeoPassportRow]=[:]
        for piece in TimeAttribution.canonical(raw) where piece.seconds>0 {
            guard let record=cache[piece.cell.id],
                  let name=level.value(record) else { continue }
            let key=TerritoryGrouping.path(for:record,through:level).map(\.id).joined(separator:" / ")
            var calendar=Calendar(identifier:.gregorian)
            calendar.timeZone=record.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
            var date=calendar.startOfDay(for:piece.start)
            var days:Set<String>=[]
            while date<piece.end {
                let c=calendar.dateComponents([.year,.month,.day],from:date)
                days.insert("\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)")
                guard let next=calendar.date(byAdding:.day,value:1,to:date),next>date else { break }
                date=next
            }
            if var existing=grouped[key] {
                existing.seconds+=piece.seconds
                existing.first=min(existing.first,piece.start)
                existing.last=max(existing.last,piece.end)
                existing.calendarDays.formUnion(days)
                grouped[key]=existing
            } else {
                grouped[key]=GeoPassportRow(id:key,name:name,
                    timeZoneIdentifier:record.timeZoneIdentifier,seconds:piece.seconds,
                    first:piece.start,last:piece.end,calendarDays:days)
            }
        }
        return grouped.values.sorted {
            $0.seconds == $1.seconds
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.seconds>$1.seconds
        }
    }
}

struct TimeGeoPassportView:View {
    @ObservedObject var model:TimeModel
    @State private var level:TerritoryLevel = .country
    private var ranked:[GeoPassportRow] {
        GeoPassportIndex.rows(model.data.intervals,cache:model.data.territoryCache,level:level)
    }
    private var available:[TerritoryLevel] {
        let known=model.data.territoryCache
        return TerritoryLevel.allCases.filter { value in
            value == .country || known.values.contains(where:{ value.value($0) != nil })
        }
    }
    var body:some View {
        List {
            Section {
                Picker("División territorial",selection:$level) {
                    ForEach(available) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                LabeledContent("Descubiertos",value:String(ranked.count))
                Text("Solo aparecen lugares realmente atribuidos a cuadrículas identificadas. Los territorios pendientes no se inventan.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(level.title) {
                if ranked.isEmpty {
                    ContentUnavailableView("Sin territorios clasificados",systemImage:"globe",
                       description:Text("Se completarán automáticamente a medida que iOS identifique nuevas cuadrículas."))
                }
                ForEach(ranked) { row in
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            Text(row.name).font(.headline)
                            Spacer(minLength:4)
                            Text(DurationFormat.full(row.seconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.teal)
                        }
                        Text("\(row.days) días de presencia")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Primera visita: \(formatted(row.first,tz:row.timeZoneIdentifier))")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("Última visita: \(formatted(row.last,tz:row.timeZoneIdentifier))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical,4)
                }
            }
        }
        .navigationTitle("Pasaporte geográfico")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func formatted(_ date:Date,tz:String?)->String {
        let f=DateFormatter()
        f.locale=Locale(identifier:"es_ES")
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone=tz.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from:date)
    }
}

struct TimeMilestone:Identifiable {
    let id:String
    let title:String
    let current:Int
    let target:Int
    let symbol:String
    var reached:Bool { current>=target }
}
enum TimeMilestones {
    static func calculate(cells:Int,zones:Int,cities:Int,countries:Int,hours:Int)->[TimeMilestone] {
        var all:[TimeMilestone]=[]
        for (name,amounts,value,symbol) in [
            ("Cuadrículas", [10,50,100,500],cells,"square.grid.3x3.fill"),
            ("Zonas", [1,5,10],zones,"square.3.layers.3d"),
            ("Ciudades", [1,5,10,25],cities,"building.2.fill"),
            ("Países", [1,3,5,10],countries,"globe"),
            ("Horas registradas", [24,100,500,1000],hours,"hourglass")
        ] {
            for target in amounts {
                all.append(TimeMilestone(id:name+"-"+String(target),title:"\(target) \(name.lowercased())",
                                         current:value,target:target,symbol:symbol))
            }
        }
        return all.sorted {
            if $0.reached != $1.reached { return $0.reached }
            return Double($0.current)/Double($0.target) >
                   Double($1.current)/Double($1.target)
        }
    }
}

struct TimeAchievementsView:View {
    @ObservedObject var model:TimeModel
    private var milestones:[TimeMilestone] {
        let totals=model.confirmedTotals()
        let ids=Set(totals.filter { $0.value>0 }.keys)
        let records=ids.compactMap { model.data.territoryCache[$0] }
        let cityCount=Set(records.compactMap { $0.city }).count
        let countryCount=Set(records.compactMap { $0.country }).count
        return TimeMilestones.calculate(cells:ids.count,zones:model.visibleZones.count,
            cities:cityCount,countries:countryCount,
            hours:Int(model.totalSeconds/3600))
    }
    var body:some View {
        let items=milestones
        List {
            Section {
                LabeledContent("Hitos conseguidos",value:"\(items.filter(\.reached).count) / \(items.count)")
                Text("Los hitos se calculan con tu historial local, sin servicio externo ni clasificación inventada.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Conseguidos y próximos") {
                ForEach(items) { item in
                    HStack(spacing:12) {
                        Image(systemName:item.reached ? "checkmark.seal.fill" : item.symbol)
                            .font(.title3)
                            .foregroundStyle(item.reached ? .teal : .secondary)
                            .frame(width:28)
                        VStack(alignment:.leading,spacing:5) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            ProgressView(value:Double(min(item.current,item.target)),
                                         total:Double(item.target))
                                .tint(item.reached ? .teal : .orange)
                            Text(item.reached ? "Conseguido" :
                                 "\(item.current) de \(item.target)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical,4)
                }
            }
        }
        .navigationTitle("Hitos de exploración")
        .navigationBarTitleDisplayMode(.inline)
    }
}
