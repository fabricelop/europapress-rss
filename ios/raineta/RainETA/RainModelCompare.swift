import Foundation
import SwiftUI

struct RainModelDaily:Identifiable {
    let id:String
    let title:String
    let totals:[Double?]
    let checkedAt:Date
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
                        URLQueryItem(name:"timezone",value:"auto"),
                        URLQueryItem(name:"forecast_days",value:name=="ARPEGE" ? "4":"7")
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
                    return RainModelDaily(id:name,title:name,totals:Array(values.prefix(7)) + Array(repeating:nil,count:max(0,7-values.count)),checkedAt:Date())
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
                          checkedAt:primary.updatedAt))
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
            Button {
                withAnimation {expanded.toggle()}
                if expanded && forecasts.isEmpty {Task {await refresh()}}
            } label:{
                HStack(alignment:.center) {
                    VStack(alignment:.leading,spacing:3) {
                        Label("Comparar modelos",systemImage:"square.stack.3d.up")
                            .font(.headline)
                        Text("Precipitación total por día · mm")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:10)
                    Text("\(forecasts.count)/5")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName:expanded ? "chevron.up":"chevron.down")
                }
            }
            .buttonStyle(.plain)
            if expanded {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:7) {
                        ForEach(0..<7,id:\.self) { day in
                            Button {
                                selectedDay=day
                            } label:{
                                Text(day==0 ? "Hoy" : day==1 ? "Mañana" : "+\(day)d")
                                    .font(.caption.bold())
                                    .padding(.horizontal,11)
                                    .padding(.vertical,8)
                                    .foregroundStyle(selectedDay==day ? .black:.white)
                                    .background(selectedDay==day ? Color.cyan:
                                                Color.white.opacity(0.10),
                                                in:Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text(dayLabel + " · lluvia acumulada estimada")
                    .font(.subheadline.bold())
                if loading {ProgressView("Consultando centros…").font(.caption)}
                let rows=selectedRows
                let maximum=max(0.5,rows.compactMap{$0.1}.max() ?? 0)
                ForEach(Array(rows.enumerated()),id:\.offset) { row in
                    let entry=row.element
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            Text(entry.0).font(.subheadline)
                            Spacer()
                            Text(entry.1.map{String(format:"%.1f mm",$0)} ?? "Sin datos")
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(entry.1 == nil ? .secondary:.cyan)
                        }
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.07))
                                .overlay(alignment:.leading) {
                                    Capsule()
                                        .fill(entry.0=="Automático" ? .mint:.cyan)
                                        .frame(width:geo.size.width *
                                               CGFloat(max(0,entry.1 ?? 0)/maximum))
                                }
                        }
                        .frame(height:7)
                    }
                    .padding(.vertical,2)
                }
                if forecasts.isEmpty && !loading {
                    Text("La previsión automática sigue disponible; los centros no han respondido.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if selectedDay>3 && forecasts.contains(where:{$0.id=="ARPEGE"}) {
                    Text("Météo-France puede no proporcionar datos más allá de 4 días.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Cada fila representa un centro meteorológico distinto. Una cifra alta significa más lluvia total en ese día; no es probabilidad de lluvia.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button {
                    Task {await refresh()}
                } label:{ Label("Actualizar comparación",systemImage:"arrow.clockwise") }
                    .font(.caption)
                    .disabled(loading)
            }
        }
        .padding(14)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
        .onChange(of:dataKey) { _,_ in
            forecasts=[]
            selectedDay=0
            if expanded {Task {await refresh()}}
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
