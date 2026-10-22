import SwiftUI
import Foundation
import MapKit

/// Funciones de consulta: no modifican las posiciones ni los intervalos originales.
struct TimeDiscoveryHome:View {
    @ObservedObject var model:TimeModel
    var body:some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        BioGridView(model:model)
                    } label: {
                        Label {
                            VStack(alignment:.leading,spacing:4) {
                                Text("BIOGRID").font(.headline)
                                Text("Siete familias de bacterias; colonización a partir de tu tiempo GPS.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName:"circle.hexagongrid.fill").foregroundStyle(.teal) }
                    }
                } header: {
                    Text("BIOGRID")
                }
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

struct TimeWhereWasIVisit:Identifiable {
    let key:String
    let name:String
    let start:Date
    let end:Date
    let seconds:TimeInterval
    let cell:Cell
    var id:String { key+"-"+String(start.timeIntervalSince1970) }
}

enum TimeWhereWasIChronology {
    // Una nueva visita cuando cambia el lugar o hay un hueco superior a 3 min.
    static func visits(_ slices:[TimeFoundSlice],
                       keyForCell:(Cell)->String,
                       nameForCell:(Cell)->String)->[TimeWhereWasIVisit] {
        let ordered=slices.sorted { $0.start<$1.start }
        var result:[TimeWhereWasIVisit]=[]
        for item in ordered {
            let key=keyForCell(item.cell)
            if let last=result.last,last.key==key,
               item.start.timeIntervalSince(last.end) <= 180 {
                result[result.count-1]=TimeWhereWasIVisit(
                    key:key,name:last.name,start:last.start,end:max(last.end,item.end),
                    seconds:last.seconds+item.seconds,cell:last.cell)
            } else {
                result.append(TimeWhereWasIVisit(key:key,name:nameForCell(item.cell),
                    start:item.start,end:item.end,seconds:item.seconds,cell:item.cell))
            }
        }
        return result
    }
}

struct TimeWhereWasIView:View {
    @ObservedObject var model:TimeModel
    @State private var from=Calendar.current.date(byAdding:.day,value:-1,to:.now) ?? .now
    @State private var to=Date()
    @State private var mapOpen=true
    private var matches:[TimeFoundSlice] {
        TimeWhereWasIIndex.slices(model.data.intervals,from:from,to:to)
    }
    private var periodTotals:[String:TimeInterval] {
        TimeWhereWasIIndex.totals(matches).reduce(into:[:]) { $0[$1.0]=$1.1 }
    }
    private var visits:[TimeWhereWasIVisit] {
        TimeWhereWasIChronology.visits(matches,
            keyForCell:{ cell in model.primaryZone(for:cell)?.id.uuidString ?? cell.id },
            nameForCell:{ cell in model.primaryZone(for:cell)?.name ?? model.label(for:cell) })
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
                let totals=periodTotals
                let history=visits
                let confirmed=slices.reduce(0) { $0+$1.seconds }
                Section("Resultado del período") {
                    LabeledContent("Tiempo localizado",value:DurationFormat.full(confirmed))
                    LabeledContent("Cuadrículas",value:String(totals.count))
                    LabeledContent("Visitas",value:String(history.count))
                    if confirmed+1<to.timeIntervalSince(from) {
                        Text("Hay tiempo sin ubicación asignable dentro del intervalo; no se dibujan ubicaciones inventadas.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !totals.isEmpty {
                    Section {
                        DisclosureGroup("Mapa del período",isExpanded:$mapOpen) {
                            TimeWhereWasIMap(totals:totals)
                                .frame(height:285)
                                .clipShape(RoundedRectangle(cornerRadius:12))
                            Text("Solo se colorean las cuadrículas con presencia dentro del comienzo y final elegidos.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Section("Lugares del período · orden cronológico") {
                        ForEach(Array(history.prefix(200))) { visit in
                            NavigationLink {
                                CellHistoryView(model:model,cell:visit.cell)
                            } label: {
                                VStack(alignment:.leading,spacing:5) {
                                    Text(visit.name).font(.subheadline.weight(.semibold))
                                    Text(visit.start.formatted(date:.abbreviated,time:.shortened)
                                         + " → " + visit.end.formatted(date:.abbreviated,time:.shortened))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(DurationFormat.full(visit.seconds))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.teal)
                                }.padding(.vertical,2)
                            }
                        }
                        if history.count>200 {
                            Text("Mostradas las primeras 200 visitas. Reduce el intervalo para ver más.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView("Sin lugares localizados",systemImage:"location.slash",
                        description:Text("Selecciona un período con posiciones GPS registradas."))
                }
            }
        }
        .navigationTitle("¿Dónde estaba?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// El filtro se representa sobre MapKit, sin reutilizar las cuadrículas de otros períodos.
private struct TimeWhereWasIMap:View {
    let totals:[String:TimeInterval]
    @State private var camera:MapCameraPosition = .automatic
    private var cells:[(Cell,TimeInterval)] {
        totals.compactMap { id,seconds in
            guard seconds>0,let cell=TimeAnalytics.cell(id) else { return nil }
            return (cell,seconds)
        }
    }
    private var maxSeconds:TimeInterval { max(1,totals.values.max() ?? 1) }
    var body:some View {
        Map(position:$camera) {
            ForEach(Array(cells.prefix(1800)),id:\.0.id) { entry in
                MapPolygon(coordinates:Grid.polygon(entry.0))
                    .foregroundStyle(Color.teal.opacity(
                        0.2+0.6*min(1,entry.1/maxSeconds)))
                    .stroke(Color.teal,lineWidth:0.8)
            }
        }
        .mapStyle(.standard)
        .onAppear { focus() }
        .onChange(of:totals) { _,_ in focus() }
        .overlay(alignment:.bottom) {
            if cells.count>1800 {
                Text("Vista limitada a 1.800 cuadrículas; reduce el período para verlas todas.")
                    .font(.caption2).padding(6)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:8))
            }
        }
    }
    private func focus() {
        let coords=cells.map { Grid.center($0.0) }
        guard let first=coords.first else { return }
        let minLat=coords.map(\.latitude).min() ?? first.latitude
        let maxLat=coords.map(\.latitude).max() ?? first.latitude
        let minLon=coords.map(\.longitude).min() ?? first.longitude
        let maxLon=coords.map(\.longitude).max() ?? first.longitude
        camera = .region(MKCoordinateRegion(
            center:CLLocationCoordinate2D(latitude:(minLat+maxLat)/2,
                                           longitude:(minLon+maxLon)/2),
            span:MKCoordinateSpan(latitudeDelta:max(0.007,(maxLat-minLat)*1.25+0.003),
                                  longitudeDelta:max(0.007,(maxLon-minLon)*1.25+0.003))))
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
