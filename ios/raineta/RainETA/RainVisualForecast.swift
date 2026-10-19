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
    private var maxRate:Double {
        max(0.7,(bins.compactMap(\.peakRate).max() ?? 0)*1.12)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label("Panorama · 2 horas",systemImage:"chart.bar.xaxis")
                    .font(.subheadline.bold())
                Spacer()
                Text("12 tramos de 10 min")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            let info=bins
            if info.isEmpty {
                Text("Sin datos para representar")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing:3) {
                    ForEach(info) { bin in
                        Button {
                            selectedMinute=bin.startMinute
                        } label:{
                            VStack(spacing:3) {
                                Spacer(minLength:0)
                                RoundedRectangle(cornerRadius:3)
                                    .fill(fillColor(bin))
                                    .frame(height:height(bin))
                                    .overlay {
                                        if selectedMinute.map({$0>=bin.startMinute &&
                                                             $0<bin.startMinute+10})==true {
                                            RoundedRectangle(cornerRadius:3)
                                                .stroke(.white,lineWidth:1.5)
                                        }
                                    }
                                Capsule()
                                    .fill(bin.radarMinutes>=5 ? Color.cyan :
                                          Color.white.opacity(0.20))
                                    .frame(height:3)
                            }
                            .frame(maxWidth:.infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(accessibility(bin))
                    }
                }
                .frame(height:91)
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
                HStack(spacing:10) {
                    Label("\(RainVisualForecast.rainyMinutes(info)) min con precipitación",
                          systemImage:"clock")
                    Spacer(minLength:0)
                    Text(hasValidRadar ? "Cian: tramo con radar" : "Previsión de modelos")
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text("Vista conjunta: intensidad equivalente estimada; tramos grises secos, " +
                     "blancos nieve prevista. La fuente cambia con el plazo.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
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

    private func fillColor(_ bin:RainOverviewBin)->Color {
        guard let amount=bin.meanRate else{return Color.gray.opacity(0.12)}
        if bin.rainyMinutes==0 {return Color.gray.opacity(0.26)}
        if bin.snow {return Color.white.opacity(0.93)}
        return RainVisual.color(amount)
    }

    private func height(_ bin:RainOverviewBin)->CGFloat {
        guard let value=bin.peakRate else{return 5}
        if bin.rainyMinutes==0{return 5}
        return max(11,CGFloat(min(1,value/maxRate))*79)
    }

    private func accessibility(_ bin:RainOverviewBin)->String {
        guard let rate=bin.meanRate else {
            return "Desde +\(bin.startMinute) minutos: datos incompletos"
        }
        return "Desde +\(bin.startMinute) minutos: \(bin.rainyMinutes) minutos de precipitación, " +
               String(format:"%.1f milímetros por hora de media",rate) +
               (bin.snow ? ", posible nieve" : "")
    }
}

struct RainTwentyFourHourView: View {
    let weather:RainSnapshot?
    @State private var selectedHour=0

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Precipitación · 24 horas",systemImage:"cloud.rain")
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
                    HStack(alignment:.firstTextBaseline) {
                        VStack(alignment:.leading,spacing:3) {
                            Text(String(format:"%.1f mm en 24 h",total))
                                .font(.title3.bold())
                            Text("Acumulación del modelo, no medida de radar")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if hours.contains(where:{$0.snowCM>=0.1}) {
                            Label("Nieve posible",systemImage:"cloud.snow.fill")
                                .font(.caption2).foregroundStyle(.white)
                        }
                    }
                    HStack {
                        Text(chosen.end.formatted(date:.omitted,time:.shortened))
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
                    twentyFourBars(hours)
                    probabilityStrip(hours)
                    HStack {
                        Text("Cantidad: mm/hora")
                        Spacer()
                        Text("Franja inferior: probabilidad")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    Text("Cada barra corresponde a una hora de acumulación prevista. " +
                         "La nieve es una estimación del modelo; la probabilidad es distinta de la cantidad.")
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

    @ViewBuilder
    private func twentyFourBars(_ hours:[Rain24Hour])->some View {
        let peak=max(0.5,(hours.map(\.millimeters).max() ?? 0)*1.12)
        HStack(alignment:.bottom,spacing:3) {
            ForEach(hours) { hour in
                Button {selectedHour=hour.index} label:{
                    VStack(spacing:5) {
                        Spacer(minLength:0)
                        RoundedRectangle(cornerRadius:3)
                            .fill(barColor(hour))
                            .frame(height:hour.isWet ?
                                   max(9,CGFloat(hour.millimeters/peak)*120):4)
                            .overlay {
                                if selectedHour==hour.index {
                                    RoundedRectangle(cornerRadius:3)
                                        .stroke(Color.white,lineWidth:1.3)
                                }
                            }
                        Text(hour.index%3==0 ?
                             hour.end.formatted(.dateTime.hour()) : " ")
                            .font(.system(size:9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(height:13)
                    }
                    .frame(maxWidth:.infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(hour.end.formatted(date:.omitted,time:.shortened)) " +
                    String(format:"%.1f mm, %d%%",hour.millimeters,hour.probability))
            }
        }
        .frame(height:153)
    }

    @ViewBuilder
    private func probabilityStrip(_ hours:[Rain24Hour])->some View {
        HStack(alignment:.bottom,spacing:3) {
            ForEach(hours) { hour in
                RoundedRectangle(cornerRadius:2)
                    .fill(Color.cyan.opacity(0.18+0.8*Double(hour.probability)/100))
                    .frame(maxWidth:.infinity)
                    .frame(height:max(3,CGFloat(hour.probability)/100*18))
                    .accessibilityLabel("\(hour.probability)% de probabilidad")
            }
        }
        .frame(height:20,alignment:.bottom)
    }

    private func barColor(_ hour:Rain24Hour)->Color {
        if !hour.isWet{return Color.gray.opacity(0.24)}
        if hour.snowCM>=0.1 {return Color.white.opacity(0.92)}
        return RainVisual.color(hour.millimeters)
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
