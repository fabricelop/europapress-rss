import Foundation
import SwiftUI

struct RainModelDaily:Identifiable {
    let id:String
    let title:String
    let totals:[Double?]
    let checkedAt:Date
}

enum RainModelCompareAPI {
    static let choices:[(String,String)]=[
        ("ECMWF","https://api.open-meteo.com/v1/ecmwf"),
        ("ICON","https://api.open-meteo.com/v1/dwd-icon"),
        ("GFS","https://api.open-meteo.com/v1/gfs")
    ]

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
                        URLQueryItem(name:"forecast_days",value:"7")
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
                    return RainModelDaily(id:name,title:name,totals:values,checkedAt:Date())
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

    private var dataKey:String {String(format:"%.3f,%.3f",coordinate,longitude)}

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label("¿Coinciden los modelos?",systemImage:"square.stack.3d.up")
                .font(.headline)
            Text("No existe un pronóstico infalible. Compara la lluvia diaria prevista en exactamente la misma ubicación.")
                .font(.caption).foregroundStyle(.secondary)
            if let main=primary {
                HStack {
                    Text("Modelo automático")
                        .frame(width:116,alignment:.leading)
                    ForEach(Array(main.days.prefix(7))) { day in
                        VStack(spacing:3) {
                            Text(RainSpanishDates.day(day.date).components(separatedBy:" ").first ?? "")
                                .font(.system(size:9))
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            Text(String(format:"%.1f",day.totalMM))
                                .font(.system(size:10,weight:.bold))
                                .foregroundStyle(day.totalMM>=0.5 ? .cyan:.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth:.infinity)
                    }
                }
                .font(.caption)
            }
            if loading {ProgressView("Consultando modelos…").font(.caption)}
            ForEach(forecasts) { model in
                HStack {
                    Text(model.title)
                        .font(.caption.bold())
                        .frame(width:116,alignment:.leading)
                    ForEach(0..<min(7,model.totals.count),id:\.self) { index in
                        let mm=model.totals[index]
                        Text(mm.map{String(format:"%.1f",$0)} ?? "—")
                            .font(.system(size:10,weight:.semibold,design:.rounded))
                            .foregroundStyle((mm ?? 0)>=0.5 ? .cyan : .secondary)
                            .frame(maxWidth:.infinity)
                    }
                }
            }
            Text("Valores en mm por día. Diferencias grandes entre modelos indican incertidumbre. Ninguno es automáticamente mejor y HelloWeather puede usar otra fuente.")
                .font(.caption2).foregroundStyle(.secondary)
            if forecasts.isEmpty && !loading {
                Text("Comparación no disponible. La previsión principal continúa funcionando.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                Task {await refresh()}
            } label:{ Label("Comparar de nuevo",systemImage:"arrow.clockwise") }
            .font(.caption)
            .disabled(loading)
        }
        .padding(14)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
        .task(id:dataKey) {await refresh()}
    }

    private func refresh() async {
        guard !loading else{return}
        loading=true
        forecasts=await RainModelCompareAPI.compare(latitude:coordinate,longitude:longitude)
        loading=false
    }
}
