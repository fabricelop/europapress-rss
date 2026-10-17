import Foundation
import SwiftUI

struct RainModelDaily:Identifiable {
    let id:String
    let title:String
    let totals:[Double?]
    let checkedAt:Date
    let hourly:[Date:Double]
}

enum RainModelCompareAPI {
    static let choices:[(String,String)]=RainShortModelAPI.endpoints.map{($0.name,$0.url)}

    static func compare(latitude:Double,longitude:Double) async -> [RainModelDaily] {
        await withTaskGroup(of:RainModelDaily?.self) { group in
            for (name,address) in choices {
                group.addTask {
                    guard var url=URLComponents(string:address) else {return nil}
                    url.queryItems=[
                        URLQueryItem(name:"latitude",value:String(latitude)),
                        URLQueryItem(name:"longitude",value:String(longitude)),
                        URLQueryItem(name:"daily",value:"precipitation_sum"),
                        URLQueryItem(name:"hourly",value:"precipitation"),
                        URLQueryItem(name:"timeformat",value:"unixtime"),
                        URLQueryItem(name:"timezone",value:"auto"),
                        URLQueryItem(name:"forecast_days",value:name=="Météo-France" || name=="JMA" ? "4":"7")
                    ]
                    guard let endpoint=url.url else {return nil}
                    var req=URLRequest(url:endpoint)
                    req.timeoutInterval=18
                    guard let (data,response)=try? await URLSession.shared.data(for:req),
                          (response as? HTTPURLResponse)?.statusCode==200,
                          let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                          let daily=json["daily"] as? [String:Any],
                          let raw=daily["precipitation_sum"] as? [Any],
                          !raw.isEmpty else {return nil}
                    let values=raw.map {($0 as? NSNumber)?.doubleValue}
                    let hours=json["hourly"] as? [String:Any] ?? [:]
                    let times=hours["time"] as? [Int] ?? []
                    let amounts=hours["precipitation"] as? [Any] ?? []
                    let hourly=Dictionary(uniqueKeysWithValues:zip(times,amounts).compactMap {
                        stamp,raw -> (Date,Double)? in
                        guard let number=raw as? NSNumber else {return nil}
                        return (Date(timeIntervalSince1970:Double(stamp)),number.doubleValue)
                    })
                    return RainModelDaily(id:name,title:name,totals:Array(values.prefix(7)) + Array(repeating:nil,count:max(0,7-values.count)),checkedAt:Date(),hourly:hourly)
                }
            }
            var list:[RainModelDaily]=[]
            for await row in group {if let row {list.append(row)}}
            return choices.compactMap { choice in list.first(where:{$0.id==choice.0}) }
        }
    }
}

struct RainMultiModelView: View {
    let coordinate:Double
    let longitude:Double
    let primary:RainSnapshot?
    @State private var forecasts:[RainModelDaily]=[]
    @State private var loading=false
    @State private var expanded=false
    @State private var selectedDay=0

    private var dataKey:String {String(format:"%.3f,%.3f",coordinate,longitude)}
    private var allModels:[RainModelDaily] {
        var rows:[RainModelDaily]=[]
        if let primary {
            rows.append(RainModelDaily(id:"auto",title:"Automático",
                          totals:Array(primary.days.prefix(7).map {Optional($0.totalMM)}),
                          checkedAt:primary.updatedAt,
                          hourly:Dictionary(uniqueKeysWithValues:primary.hours.map{($0.time,$0.millimeters)})))
        }
        rows.append(contentsOf:forecasts)
        return rows
    }
    private var dayLabel:String {
        guard let primary,primary.days.indices.contains(selectedDay) else {
            return ["Hoy","Mañana","Día 3","Día 4","Día 5","Día 6","Día 7"][selectedDay]
        }
        return selectedDay == 0 ? "Hoy" : selectedDay == 1 ? "Mañana" :
            primary.days[selectedDay].date.formatted(.dateTime.weekday(.wide))
    }
    private var selectedRows:[(String,Double?)] {
        allModels.map {($0.title,$0.totals.indices.contains(selectedDay) ?
                       $0.totals[selectedDay] : nil)}
    }

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            header
            if expanded { comparisonDetails }
        }
        .padding(14)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
        .onChange(of:dataKey) { _,_ in
            forecasts=[]
            selectedDay=0
            if expanded {Task {await refresh()}}
        }
    }

    private var header:some View {
        Button {
            withAnimation {expanded.toggle()}
            if expanded && forecasts.isEmpty {Task {await refresh()}}
        } label:{
            HStack(alignment:.center) {
                VStack(alignment:.leading,spacing:3) {
                    Label("Comparar modelos",systemImage:"square.stack.3d.up")
                        .font(.headline)
                    Text("Acuerdo y diferencias · lluvia diaria en mm")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength:10)
                Text("\(forecasts.count)/\(RainShortModelAPI.endpoints.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName:expanded ? "chevron.up":"chevron.down")
            }
        }
        .buttonStyle(.plain)
    }

    private var dayPicker:some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:7) {
                ForEach(0..<7,id:\.self) { day in
                    Button {selectedDay=day} label:{
                        Text(day==0 ? "Hoy" : day==1 ? "Mañana" : "+\(day)d")
                            .font(.caption.bold())
                            .padding(.horizontal,11)
                            .padding(.vertical,8)
                            .foregroundStyle(selectedDay==day ? Color.black:Color.white)
                            .background(selectedDay==day ? Color.cyan:
                                        Color.white.opacity(0.10),in:Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var comparisonDetails:some View {
        VStack(alignment:.leading,spacing:12) {
            dayPicker
            Text(dayLabel + " · lluvia acumulada estimada")
                .font(.subheadline.bold())
            let available=selectedRows.compactMap{$0.1}
            if !available.isEmpty {
                let wet=available.filter{$0>=0.1}.count
                Text("\(wet)/\(available.count) fuentes prevén lluvia · intervalo " +
                     String(format:"%.1f–%.1f mm",available.min() ?? 0,available.max() ?? 0))
                    .font(.caption.bold())
                    .foregroundStyle(wet>0 && wet<available.count ? .yellow:.cyan)
            }
            if loading {ProgressView("Consultando centros…").font(.caption)}
            hourlyMatrix
            modelRows
            if forecasts.isEmpty && !loading {
                Text("La previsión automática sigue disponible; los centros no han respondido.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if selectedDay>3 && forecasts.contains(where:{$0.id=="Météo-France"}) {
                Text("Météo-France puede no proporcionar datos más allá de 4 días.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Cada fila es un centro meteorológico. Se indican milímetros acumulados, no probabilidad de lluvia.")
                .font(.caption2).foregroundStyle(.secondary)
            Button {Task {await refresh()}} label:{
                Label("Actualizar comparación",systemImage:"arrow.clockwise")
            }
            .font(.caption)
            .disabled(loading)
        }
    }

    private var modelRows:some View {
        let rows=selectedRows
        let peak=max(0.5,rows.compactMap{$0.1}.max() ?? 0)
        return VStack(alignment:.leading,spacing:10) {
            ForEach(Array(rows.enumerated()),id:\.offset) { row in
                RainModelCompareRow(name:row.element.0,
                                    amount:row.element.1,maximum:peak)
            }
        }
    }

    private var hourlyMatrix:some View {
        let start=Calendar.current.startOfDay(for:
            primary?.days.indices.contains(selectedDay)==true ?
                primary!.days[selectedDay].date :
                Calendar.current.date(byAdding:.day,value:selectedDay,to:Date()) ?? Date())
        return VStack(alignment:.leading,spacing:7) {
            Text("LLUVIA POR HORA · 00–23").font(.caption2.bold()).foregroundStyle(.cyan)
            ScrollView(.horizontal,showsIndicators:true) {
                VStack(alignment:.leading,spacing:5) {
                    HStack(spacing:2) {
                        Text("Hora").frame(width:85,alignment:.leading)
                        ForEach(0..<24,id:\.self) { hour in
                            Text(String(format:"%02d",hour))
                                .font(.system(size:9,weight:.bold,design:.rounded))
                                .frame(width:24)
                        }
                    }
                    ForEach(allModels) { model in
                        HStack(spacing:2) {
                            Text(model.title).font(.system(size:10))
                                .lineLimit(1).frame(width:85,alignment:.leading)
                            ForEach(0..<24,id:\.self) { hour in
                                let target=Calendar.current.date(byAdding:.hour,
                                    value:hour,to:start) ?? start
                                let amount=model.hourly.first {
                                    Calendar.current.isDate($0.key,equalTo:target,toGranularity:.hour)
                                }?.value
                                RoundedRectangle(cornerRadius:3)
                                    .fill(amount.map { $0>=0.1 ?
                                        RainVisual.color(max(0.3,$0)) :
                                        Color.mint.opacity(0.20) } ?? .gray.opacity(0.16))
                                    .frame(width:24,height:18)
                                    .accessibilityLabel("\(model.title), \(hour) horas, " +
                                        (amount.map{String(format:"%.1f milímetros",$0)} ?? "sin datos"))
                            }
                        }
                    }
                }
            }
            Text("Color: lluvia prevista; verde tenue: seco; gris: sin datos. Pulsa una fila inferior para ver el acumulado.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func refresh() async {
        guard !loading else{return}
        loading=true
        let key=dataKey
        let results=await RainModelCompareAPI.compare(latitude:coordinate,longitude:longitude)
        if key==dataKey {forecasts=results}
        loading=false
    }
}

private struct RainModelCompareRow:View {
    let name:String
    let amount:Double?
    let maximum:Double

    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(name).font(.subheadline)
                Spacer()
                Text(amount.map{String(format:"%.1f mm",$0)} ?? "Sin datos")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(amount == nil ? Color.secondary : Color.cyan)
            }
            GeometryReader { geometry in
                Capsule().fill(Color.white.opacity(0.07))
                    .overlay(alignment:.leading) {
                        Capsule()
                            .fill(name=="Automático" ? Color.mint : Color.cyan)
                            .frame(width:geometry.size.width *
                                   CGFloat(max(0,amount ?? 0)/max(0.5,maximum)))
                    }
            }
            .frame(height:7)
        }
        .padding(.vertical,2)
    }
}
