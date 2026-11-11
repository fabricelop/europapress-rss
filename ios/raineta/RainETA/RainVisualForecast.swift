import SwiftUI

// MARK: - Display-only summaries of existing forecast inputs
// 0–120 minutes: radar-informed minutes when valid; otherwise modelled
// intervals. Ten-minute column width is VISUAL aggregation, not new data.
struct RainOverviewBin: Identifiable {
    let startMinute: Int
    let meanRate: Double?
    let peakRate: Double?
    let rainyMinutes: Int
    let radarMinutes: Int
    let snow: Bool
    var id: Int { startMinute }
}

enum RainVisualForecast {
    static func overview(_ minutes: [RadarWeightedMinute],
                         weather: RainSnapshot?,
                         horizon: Int = 120,
                         binSize: Int = 10) -> [RainOverviewBin] {
        guard horizon > 0,binSize > 0 else {return []}
        let lookup=Dictionary(uniqueKeysWithValues:minutes.map {($0.minute,$0)})
        return stride(from:0,to:horizon,by:binSize).map { start in
            let batch=(start..<min(start+binSize,horizon)).compactMap {lookup[$0]}
            // A partly unavailable interval must not automatically appear dry.
            let valid=batch.count >= max(1,Int(Double(min(binSize,horizon-start))*0.8))
            let mean=valid ? batch.reduce(0.0){$0+$1.rate}/Double(batch.count) : nil
            let peak=valid ? batch.map(\.rate).max() : nil
            let isSnow=batch.contains {item in
                item.rate >= 0.15 && weather?.phase(at:item.at) == .snow
            }
            return RainOverviewBin(
                startMinute:start,meanRate:mean,peakRate:peak,
                rainyMinutes:batch.filter{$0.rate>=0.15}.count,
                radarMinutes:batch.filter(\.radarInformed).count,
                snow:isSnow
            )
        }
    }

    static func rainyMinutes(_ bins:[RainOverviewBin]) -> Int {
        bins.reduce(0){$0+$1.rainyMinutes}
    }

    static func liquidEquivalent(_ series:[RadarWeightedMinute]) -> Double {
        series.reduce(0.0){$0 + max(0,$1.rate)/60.0}
    }

    static func estimatedNextChange(_ bins:[RainOverviewBin],
                                    rainingNow:Bool) -> Int? {
        // Do not issue minute-perfect predictions from 10-min visual bins.
        bins.first(where:{
            $0.meanRate != nil &&
            ($0.rainyMinutes>=5) != rainingNow &&
            $0.startMinute >= (rainingNow ? 10:0)
        })?.startMinute
    }

    static func daily24(_ snapshot:RainSnapshot,now:Date) -> [Rain24Hour] {
        let candidates=snapshot.hours.filter {
            $0.time>now && $0.time<=now.addingTimeInterval(25*3600)
        }.sorted{$0.time<$1.time}
        return Array(candidates.prefix(24)).enumerated().map { index,hour in
            let snow=snapshot.snowHours.first {
                abs($0.end.timeIntervalSince(hour.time))<60
            }?.centimeters ?? 0
            return Rain24Hour(index:index,end:hour.time,
                    millimeters:max(0,hour.millimeters),
                    probability:max(0,min(100,hour.probability)),
                    snowCM:max(0,snow),temperature:hour.temperature)
        }
    }
}

struct Rain24Hour: Identifiable {
    let index:Int
    let end:Date
    let millimeters:Double
    let probability:Int
    let snowCM:Double
    let temperature:Double?
    var id:Int {index}
    var isWet:Bool {millimeters>=0.1 || snowCM>=0.1}
}

struct RainPulseOverview:View {
    let series:[RadarWeightedMinute]
    let weather:RainSnapshot?
    let hasValidRadar:Bool
    @Binding var selectedMinute:Int?

    private var bins:[RainOverviewBin] {
        RainVisualForecast.overview(series,weather:weather)
    }

    private var wave:[RainWavePoint] {
        bins.map { bin in
            RainWavePoint(minute:bin.startMinute,rate:bin.meanRate,snow:bin.snow)
        }
    }

    private var selectedIndex:Int? {
        guard let selected=selectedMinute else {return nil}
        return bins.firstIndex(where:{ bin in
            selected>=bin.startMinute && selected<bin.startMinute+10
        })
    }

    private var waveform:some View {
        VStack(alignment:.leading,spacing:8) {
            RainWavePlot(points:wave,height:134,
                         selectedIndex:selectedIndex,
                         onSelect:{ index in
                             let values=bins
                             if values.indices.contains(index) {
                                 selectedMinute=values[index].startMinute
                             }
                         })
            HStack {
                Text("Ahora")
                Spacer()
                Text("+30")
                Spacer()
                Text("+60")
                Spacer()
                Text("+90")
                Spacer()
                Text("+120 min")
            }
            .font(.system(size:10,design:.rounded))
            .foregroundStyle(.secondary)
            RainWaveRibbon(points:wave)
            RainWaveWindows(points:wave,stepMinutes:10,limit:4)
            RainWaveLegend()
        }
    }

    private var information:some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:10) {
                Label(bins.contains(where:{$0.meanRate==nil}) ?
                      "\(RainVisualForecast.rainyMinutes(bins)) min con precipitación · datos parciales" :
                      "\(RainVisualForecast.rainyMinutes(bins)) min con precipitación estimada",
                      systemImage:"clock")
                Spacer(minLength:0)
                Text(hasValidRadar ? "Con radar local" : "Según modelos")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("La onda azul representa intensidad estimada. Violeta: señal débil. " +
                 "Gris: falta de datos. Los bloques de 10 min no son mediciones independientes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)
        }
    }

    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label("Panorama · 2 horas",systemImage:"waveform.path")
                    .font(.subheadline.bold())
                Spacer()
                Text("RADAR → MODELOS")
                    .font(.system(size:10,weight:.semibold))
                    .foregroundStyle(.cyan)
            }
            if bins.isEmpty || bins.allSatisfy({$0.meanRate == nil}) {
                Text("Sin datos suficientes para representar las próximas 2 horas")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment:.firstTextBaseline) {
                    Text("¿Cuándo llueve y cuándo no?")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(RainWaveForecast.peak(wave)>0 ?
                         String(format:"Pico ~%.1f mm/h",RainWaveForecast.peak(wave)) :
                         "Sin pico relevante")
                        .font(.caption2.bold())
                        .foregroundStyle(.cyan)
                }
                waveform
                information
            }
        }
        .padding(12)
        .background(
            LinearGradient(colors:[Color.cyan.opacity(0.11),
                                   Color.indigo.opacity(0.06)],
                           startPoint:.topLeading,endPoint:.bottomTrailing),
            in:RoundedRectangle(cornerRadius:16))
        .overlay(RoundedRectangle(cornerRadius:16)
                 .stroke(Color.cyan.opacity(0.17),lineWidth:1))
    }
}

struct RainTwentyFourHourView: View {
    let weather:RainSnapshot?
    @State private var selectedHour=0

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Precipitación · 24 horas",systemImage:"waveform.path")
                    .font(.headline)
                Spacer()
                Text("LLUVIA / NIEVE")
                    .font(.system(size:10,weight:.bold))
                    .foregroundStyle(.cyan)
            }
            if let weather {
                let hours=RainVisualForecast.daily24(weather,now:Date())
                if hours.isEmpty {
                    Text("Previsión horaria no disponible")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let chosen=hours[min(max(0,selectedHour),hours.count-1)]
                    let total=hours.reduce(0.0){$0+$1.millimeters}
                    let points=hours.map {
                        RainWavePoint(minute:$0.index*60,rate:$0.millimeters,
                                      probability:Double($0.probability),
                                      snow:$0.snowCM>=0.1,
                                      date:$0.end.addingTimeInterval(-3600))
                    }
                    HStack(alignment:.firstTextBaseline) {
                        VStack(alignment:.leading,spacing:3) {
                            Text(String(format:"%.1f mm en 24 h",total))
                                .font(.title3.bold())
                            Text("Acumulación del modelo · no es radar observado")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if hours.contains(where:{$0.snowCM>=0.1}) {
                            Label("Nieve posible",systemImage:"cloud.snow.fill")
                                .font(.caption2).foregroundStyle(.white)
                        }
                    }
                    if let first=RainWaveForecast.firstRain(points),
                       hours.indices.contains(first.first) {
                        Text("Lluvia prevista desde ~" +
                             hours[first.first].end.addingTimeInterval(-3600)
                                .formatted(date:.omitted,time:.shortened))
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)
                    } else {
                        Text(points.contains(where:{RainWaveForecast.signal($0)==(.possible)}) ?
                             "Señales posibles, sin episodio probable definido" :
                             "Sin episodio relevante previsto en esta franja")
                            .font(.subheadline.bold()).foregroundStyle(.mint)
                    }
                    HStack {
                        Text(chosen.end.addingTimeInterval(-3600)
                            .formatted(date:.omitted,time:.shortened) +
                             "–" + chosen.end.formatted(date:.omitted,time:.shortened))
                            .font(.caption.bold())
                        Spacer()
                        Text(String(format:"%.1f mm",chosen.millimeters))
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.cyan)
                        Text("\(chosen.probability)%")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.secondary)
                        if chosen.snowCM>=0.1 {
                            Text(String(format:"%.1f cm nieve",chosen.snowCM))
                                .font(.caption2).foregroundStyle(.white)
                        }
                    }
                    RainWavePlot(points:points,height:140,
                                 selectedIndex:min(max(0,selectedHour),hours.count-1),
                                 onSelect:{ index in
                                     if hours.indices.contains(index) {selectedHour=index}
                                 })
                    HStack {
                        Text(hours.first?.end.addingTimeInterval(-3600)
                            .formatted(date:.omitted,time:.shortened) ?? "Ahora")
                        Spacer()
                        Text("+12 h")
                        Spacer()
                        Text("+24 h")
                    }
                    .font(.system(size:10,design:.rounded))
                    .foregroundStyle(.secondary)
                    RainWaveRibbon(points:points)
                    RainWaveWindows(points:points,stepMinutes:60,limit:5)
                    RainWaveLegend()
                    Text("La onda indica acumulación horaria en mm (equivalente a mm/h por tramo). " +
                         "La probabilidad se evalúa aparte; las franjas violetas representan riesgo incierto.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
            } else {
                ProgressView("Consultando previsión de precipitación…")
            }
        }
        .padding(15)
        .background(Color.white.opacity(0.065),
                    in:RoundedRectangle(cornerRadius:20))
    }
}

/// Twelve bins covering the same interval and vertical intensity scale for
/// every model. Their hourly input cannot imply a new 10-minute prediction.
struct RainModelPulseStrip: View {
    let model: RainShortModel
    let now: Date
    let horizon: Int
    let sharedPeak: Double

    var body: some View {
        let bins=Array(stride(from:0,to:max(1,horizon),by:10))
        HStack(alignment:.bottom,spacing:3) {
            ForEach(bins,id:\.self) { minute in
                let rain=model.rateMMH(at:now.addingTimeInterval(Double(minute*60)))
                RoundedRectangle(cornerRadius:2)
                    .fill(rain == nil ? Color.gray.opacity(0.13) :
                          rain!<0.1 ? Color.gray.opacity(0.30) :
                          RainVisual.color(rain!))
                    .frame(maxWidth:.infinity)
                    .frame(height:rain.map{
                        $0<0.1 ? 4 : max(5,CGFloat($0/max(0.5,sharedPeak))*30)
                    } ?? 4,alignment:.bottom)
            }
        }
        .frame(height:31,alignment:.bottom)
        .accessibilityLabel("Precipitación horaria por modelo, representada en bloques visuales de diez minutos")
    }
}
