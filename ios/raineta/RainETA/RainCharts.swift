import SwiftUI
import Charts

struct RainIntensityLegend: View {
    private let levels:[(String,Double)] = [
        ("Seco",0),("Fina",0.3),("Débil",1.2),
        ("Media",4),("Fuerte",10),("Muy fuerte",18)
    ]
    var body: some View {
        HStack(spacing:5) {
            ForEach(0..<levels.count,id:\.self) { index in
                let level=levels[index]
                VStack(spacing:4) {
                    RoundedRectangle(cornerRadius:3)
                        .fill(RainVisual.color(level.1))
                        .frame(height:7)
                    Text(level.0)
                        .font(.system(size:9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth:.infinity)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children:.combine)
    }
}

// The short-range pulse shows actual separate minute slots on a scrollable
// scale. Each slot inherits the temporal resolution of its source (typically
// 15 minutes for Best Match, 60 minutes for individual NWP providers).
private struct RainMinuteBar:Identifiable {
    let minute:Int
    let mmh:Double?
    var probability:Int? = nil
    var id:Int {minute}
    var wet:Bool { (mmh ?? 0) >= 0.15 }
}

private enum RainBarDisplay {
    static func summary(_ points:[RainMinuteBar],rainingNow:Bool) -> String {
        guard !points.isEmpty, points.contains(where:{$0.mmh != nil})
        else {return "Sin datos suficientes"}
        // A model refresh can disagree with a current observation; avoid
        // claiming that the rain stops in a single interpolated minute.
        func sustained(_ start:Int,expectRain:Bool)->Bool {
            guard start>=0,start+5<=points.count else{return false}
            return points[start..<(start+5)].allSatisfy {
                $0.mmh != nil && $0.wet==expectRain
            }
        }
        if rainingNow {
            if let stop=points.first(where:{$0.minute>=5 &&
                    sustained($0.minute,expectRain:false)}) {
                return "Llueve ahora · posible final en +\(stop.minute) min"
            }
            return "Llueve ahora · sin final claro en este intervalo"
        }
        if let start=points.first(where:{sustained($0.minute,expectRain:true)}) {
            return "Seco ahora · posible lluvia en +\(start.minute) min"
        }
        return "Sin lluvia apreciable en este intervalo"
    }
}

private struct RainMinuteBarCell:View {
    let point:RainMinuteBar
    let height:CGFloat
    let width:CGFloat
    let selected:Bool
    let action:() -> Void

    private var barColor:Color {
        guard let rate=point.mmh else { return .gray.opacity(0.22) }
        return point.wet ? RainVisual.color(rate) : .mint.opacity(0.25)
    }
    private var spoken:String {
        let rate=point.mmh.map { String(format:"%.1f milímetros por hora",$0) }
                   ?? "sin dato"
        let chance=point.probability.map { ", probabilidad \($0) por ciento" } ?? ""
        return "Minuto \(point.minute), " + rate + chance
    }
    var body:some View {
        Button(action:action) {
            RoundedRectangle(cornerRadius:2)
                .fill(barColor)
                .frame(width:width,height:height)
                .shadow(color:point.wet ? barColor.opacity(0.75) : .clear,
                        radius:point.wet ? 6 : 0)
                .overlay(alignment:.top) {
                    if selected { Rectangle().stroke(.white,lineWidth:1.5) }
                }
                .frame(width:width,height:105,alignment:.bottom)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
    }
}

private struct RainMinuteBars:View {
    let data:[RainMinuteBar]
    let horizon:Int
    let now:Date
    @Binding var selectedMinute:Int?
    @State private var scrollID=0

    private let barWidth:CGFloat=7
    private let spacing:CGFloat=2
    private var maxRate:Double {
        max(0.6,(data.compactMap(\.mmh).max() ?? 0)*1.10)
    }

    var body:some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal,showsIndicators:true) {
                VStack(alignment:.leading,spacing:6) {
                    HStack(alignment:.bottom,spacing:spacing) {
                        ForEach(data) { point in
                            RainMinuteBarCell(point:point,
                                height:barHeight(point),width:barWidth,
                                selected:selectedMinute==point.minute) {
                                selectedMinute=point.minute
                            }
                            .id(point.minute)
                        }
                    }
                    HStack(spacing:0) {
                        ForEach(0...horizon/30,id:\.self) { i in
                            Text(i == 0 ? "Ahora" :
                                 now.addingTimeInterval(Double(i*30*60))
                                    .formatted(date:.omitted,time:.shortened))
                                .font(.system(size:10,weight:.medium,design:.rounded))
                                .foregroundStyle(.secondary)
                                .frame(width:CGFloat(30)*(barWidth+spacing),
                                       alignment:.leading)
                        }
                    }
                }
                .padding(.vertical,5)
            }
            .onChange(of:horizon) {_,_ in
                selectedMinute=nil
                withAnimation {reader.scrollTo(0,anchor:.leading)}
            }
        }
        .frame(height:145)
        .accessibilityLabel("Barras de precipitación, una por cada minuto. Deslizar horizontalmente.")
    }

    private func barHeight(_ value:RainMinuteBar)->CGFloat {
        guard let mm=value.mmh else{return 3}
        if !value.wet {return 4}
        return max(12,CGFloat(min(1,max(0,mm)/maxRate))*97)
    }
}

struct MinuteRainGraph:View {
    @ObservedObject var store:RainStore
    @AppStorage("raineta.settings.defaultHorizon") private var horizon=60
    @State private var selectedMinute:Int?
    @State private var showModels=false

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Pulso de lluvia",systemImage:"waveform.path")
                    .font(.headline)
                Spacer()
                Text("1 BARRA / MIN")
                    .font(.system(size:10,weight:.bold))
                    .foregroundStyle(.cyan)
            }
            Picker("Tiempo",selection:$horizon) {
                Text("30 min").tag(30)
                Text("60 min").tag(60)
                Text("120 min").tag(120)
            }
            .pickerStyle(.segmented)
            let now=Date()
            let rows=store.minuteForecast(now:now,horizon:horizon)
            let bars=rows.map { point in
                let chance=store.snapshot?.samples.min(by:{
                    abs($0.time.timeIntervalSince(point.at)) <
                    abs($1.time.timeIntervalSince(point.at))
                })?.probability
                return RainMinuteBar(minute:point.minute,mmh:point.rate,
                                     probability:chance)
            }
            if bars.isEmpty {
                ContentUnavailableView("Sin previsión local",systemImage:"cloud.slash",
                    description:Text("Actualiza la previsión de este lugar."))
                    .frame(height:125)
            } else {
                let selected=rows.min(by:{
                    abs($0.minute-(selectedMinute ?? 0)) <
                    abs($1.minute-(selectedMinute ?? 0))
                }) ?? rows[0]
                let isRaining=store.shortEstimate?.isUsable(at:now)==true ?
                    (store.shortEstimate?.rainingNow ?? false) :
                    (store.snapshot?.isRaining ?? false)
                Text(RainBarDisplay.summary(bars,rainingNow:isRaining))
                    .font(.subheadline.bold())
                    .foregroundStyle(.cyan)
                    .fixedSize(horizontal:false,vertical:true)
                HStack(alignment:.firstTextBaseline) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(selectedMinute == nil ? "Ahora" :
                             selected.at.formatted(date:.omitted,time:.shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(RainVisual.intensity(selected.rate))
                            .font(.title3.bold())
                            .foregroundStyle(RainVisual.color(selected.rate))
                    }
                    Spacer()
                    Text(String(format:"%.1f mm/h",selected.rate))
                        .font(.title3.bold().monospacedDigit())
                }
                HStack(spacing:10) {
                    Label("Prob. modelo " + (bars.first(where:{$0.minute==selected.minute})?.probability
                          .map{"\($0)%"} ?? "—"),systemImage:"percent")
                        .foregroundStyle(.mint)
                    Spacer()
                    let votes=store.shortModels.compactMap{$0.predictsRain(at:selected.at)}
                    Text(votes.isEmpty ? "Sin consenso disponible" :
                         "\(votes.filter{$0}.count)/\(votes.count) modelos ven lluvia")
                        .foregroundStyle(.cyan)
                }
                .font(.caption.bold())
                if store.radarLocal?.isFresh(at:now)==true {
                    Label(selected.radarInformed ? "Radar local + nowcast" : "Previsión por modelos",
                          systemImage:"dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(selected.radarInformed ? .cyan:.secondary)
                } else {
                    Text("Sin cobertura radar local válida · previsión por modelos")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                RainMinuteBars(data:bars,horizon:horizon,now:now,
                               selectedMinute:$selectedMinute)
                HStack(spacing:6) {
                    Text("Gris: sin lluvia")
                    Spacer()
                    Text("Color: intensidad")
                    Spacer()
                    Image(systemName:"hand.draw").foregroundStyle(.secondary)
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text("Barras por minuto; datos de origen por intervalos. % y votos son distintos.")
                    .font(.caption2).foregroundStyle(.secondary)

                Button {
                    withAnimation {showModels.toggle()}
                } label:{
                    HStack {
                        Label(showModels ? "Ocultar comparación" : "Comparar cada modelo",
                              systemImage:"square.stack.3d.up")
                        Spacer(minLength:4)
                        Text("\(store.shortModels.count)/\(RainShortModelAPI.endpoints.count) fuentes")
                            .font(.caption2).foregroundStyle(.secondary)
                        Image(systemName:showModels ? "chevron.up":"chevron.down")
                    }
                    .font(.subheadline.bold())
                }
                .buttonStyle(.plain)
                if showModels {
                    RainConsensusMatrix(models:store.shortModels,now:now,horizon:horizon,
                                        step:15)
                }
            }
        }
        .padding(15)
        .background(LinearGradient(colors:[.cyan.opacity(0.17),.indigo.opacity(0.13),.black.opacity(0.22)],
                                   startPoint:.topLeading,endPoint:.bottomTrailing),
                    in:RoundedRectangle(cornerRadius:20))
    }
}

/// One shared time axis makes disagreement visible without eight duplicate charts.
private struct RainConsensusMatrix:View {
    let models:[RainShortModel]
    let now:Date
    let horizon:Int
    let step:Int
    @State private var selected=0

    private var slots:[Int] {Array(stride(from:0,through:horizon,by:step))}
    private func time(_ minute:Int)->Date {now.addingTimeInterval(Double(minute*60))}
    private func values(_ minute:Int)->[Double] {
        models.compactMap{$0.rateMMH(at:time(minute))}
    }
    private func rainColor(_ rate:Double?)->Color {
        guard let rate else {return .gray.opacity(0.20)}
        return rate>=0.1 ? RainVisual.color(max(0.3,rate)) : .mint.opacity(0.25)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Text("CONSENSO POR HORA").font(.caption2.bold()).foregroundStyle(.cyan)
                Spacer()
                let counts=values(selected)
                Text("\(counts.filter{$0>=0.1}.count)/\(counts.count) lluvia")
                    .font(.caption.bold().monospacedDigit())
            }
            ScrollView(.horizontal,showsIndicators:true) {
                VStack(alignment:.leading,spacing:5) {
                    HStack(spacing:3) {
                        Text("Hora").frame(width:88,alignment:.leading)
                        ForEach(slots,id:\.self) { minute in
                            Button {
                                selected=minute
                            } label:{
                                Text(time(minute).formatted(date:.omitted,time:.shortened))
                                    .font(.system(size:9,weight:.bold,design:.rounded))
                                    .frame(width:51)
                                    .foregroundStyle(selected==minute ? .white:.secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing:3) {
                        Text("Acuerdo").font(.caption2.bold()).frame(width:88,alignment:.leading)
                        ForEach(slots,id:\.self) { minute in
                            let rates=values(minute)
                            let wet=rates.filter{$0>=0.1}.count
                            GeometryReader { geo in
                                HStack(spacing:0) {
                                    Rectangle().fill(.cyan).frame(width:geo.size.width *
                                        CGFloat(wet)/CGFloat(max(1,rates.count)))
                                    Rectangle().fill(.mint.opacity(0.25))
                                }
                            }
                            .frame(width:51,height:17)
                            .clipShape(RoundedRectangle(cornerRadius:4))
                            .overlay {Text("\(wet)/\(rates.count)")
                                .font(.system(size:9,weight:.heavy,design:.rounded))}
                        }
                    }
                    ForEach(models,id:\.name) { model in
                        HStack(spacing:3) {
                            Text(model.name).font(.system(size:10,weight:.medium))
                                .lineLimit(1).frame(width:88,alignment:.leading)
                            ForEach(slots,id:\.self) { minute in
                                let rate=model.rateMMH(at:time(minute))
                                RoundedRectangle(cornerRadius:4)
                                    .fill(rainColor(rate))
                                    .frame(width:51,height:19)
                                    .overlay {Text(rate.map{String(format:"%.1f",$0)} ?? "—")
                                        .font(.system(size:9,weight:.bold).monospacedDigit())}
                                    .accessibilityLabel("\(model.name), \(time(minute).formatted(date:.omitted,time:.shortened)), " +
                                        (rate.map{String(format:"%.1f milímetros por hora",$0)} ?? "sin datos"))
                            }
                        }
                    }
                }
            }
            if models.isEmpty {Text("Consultando modelos…").font(.caption).foregroundStyle(.secondary)}
            Text("Celdas: mm/h medios de la hora del modelo. Color: intensidad; acuerdo: votos, no probabilidad.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.indigo.opacity(0.18),in:RoundedRectangle(cornerRadius:13))
    }
}

struct ThreeHourRainView:View {
    @ObservedObject var store:RainStore
    @State private var chosen:Int=0
    @State private var showModels=false

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Próximas 3 horas",systemImage:"chart.bar.fill")
                .font(.headline)
            if store.snapshot != nil {
                let now=Date()
                let series=store.minuteForecast(now:now,horizon:180)
                let slots=stride(from:0,through:180,by:15).compactMap { minute in
                    series.first(where:{$0.minute==minute})
                }
                if slots.isEmpty {
                    Text("Sin datos para las próximas horas").foregroundStyle(.secondary)
                } else {
                    let selected=slots.min(by:{abs($0.minute-chosen)<abs($1.minute-chosen)}) ?? slots[0]
                    Text(store.radarLocal?.isFresh(at:now)==true ?
                         "Radar local de 0 a 60 min; influencia decreciente hasta 90 min. Después, modelos." :
                         "Radar local no disponible · previsión de modelos")
                        .font(.caption2).foregroundStyle(.cyan)
                    HStack(spacing:6) {
                        Text(selected.at.formatted(date:.omitted,time:.shortened))
                            .font(.subheadline.bold())
                        Spacer()
                        Text(String(format:"%.1f mm/h",selected.rate))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(RainVisual.color(selected.rate))
                        Text(selected.radarInformed ? "Radar" : "Modelo")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal,showsIndicators:true) {
                        HStack(spacing:7) {
                            ForEach(slots) { point in
                                let chance=store.snapshot?.samples.min(by:{
                                    abs($0.time.timeIntervalSince(point.at)) <
                                    abs($1.time.timeIntervalSince(point.at))
                                })?.probability
                                Button {chosen=point.minute} label:{
                                    VStack(spacing:7) {
                                        Text(point.minute==0 ? "AHORA" : point.at.formatted(date:.omitted,time:.shortened))
                                            .font(.system(size:10,weight:.heavy,design:.rounded))
                                        Image(systemName:point.rate>=0.15 ? "cloud.rain.fill":"sun.max.fill")
                                            .font(.title3)
                                        Text(String(format:"%.1f",point.rate))
                                            .font(.caption.bold().monospacedDigit())
                                        Text(chance.map{"\($0)%"} ?? "—")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.mint)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(width:65,height:106)
                                    .background(LinearGradient(colors:[
                                        RainVisual.color(point.rate).opacity(0.85),
                                        .indigo.opacity(0.48)],
                                        startPoint:.top,endPoint:.bottom),
                                        in:RoundedRectangle(cornerRadius:16))
                                    .overlay(RoundedRectangle(cornerRadius:16)
                                        .stroke(chosen==point.minute ? .white:.cyan.opacity(0.18),
                                                lineWidth:chosen==point.minute ? 2:1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Text("Tarjetas de 15 min: intensidad media en mm/h y probabilidad del modelo. Radar cuando hay nowcast local válido.")
                        .font(.caption2).foregroundStyle(.secondary)
                    RainIntensityLegend()
                    HStack {
                        let wet=series.filter{$0.rate>=0.15}.count
                        Label("~\(wet) min con precipitación estimada",systemImage:"clock")
                        Spacer()
                        Text("Radar + modelos")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    Button {withAnimation {showModels.toggle()}} label:{
                        HStack {
                            Label(showModels ? "Ocultar modelos" : "Ver todos los modelos juntos",
                                  systemImage:"square.stack.3d.up")
                            Spacer()
                            Text("\(store.shortModels.count)/\(RainShortModelAPI.endpoints.count)")
                        }
                        .font(.subheadline.bold())
                    }
                    if showModels {
                        RainConsensusMatrix(models:store.shortModels,now:now,horizon:180,
                                            step:15)
                    }
                }
            } else {
                ProgressView("Consultando previsión…")
            }
        }
        .padding(15)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
    }
}

struct LongRainForecast: View {
    let weather:RainSnapshot?
    @State private var hours=72

    private var shown:[HourlyRain] {
        guard let weather else { return [] }
        return Array(weather.hours.filter{$0.time>=Date().addingTimeInterval(-3600)}.prefix(hours))
    }

    var body:some View {
        VStack(alignment:.leading,spacing:13) {
            Label("Previsión por horas y días",systemImage:"calendar")
                .font(.headline)
            Picker("Horizonte",selection:$hours) {
                Text("24 horas").tag(24)
                Text("72 horas").tag(72)
                Text("7 días").tag(168)
            }.pickerStyle(.segmented)
            let data=shown
            if !data.isEmpty {
                Chart(data) { item in
                    BarMark(x:.value("Hora",item.time),
                            y:.value("mm",item.millimeters))
                        .foregroundStyle(RainVisual.color(item.millimeters))
                }
                .chartXAxis {
                    AxisMarks(values:.stride(by:hours == 168 ? .day : .hour,
                                              count:hours == 24 ? 4 : hours == 72 ? 12 : 1)) { _ in
                        AxisValueLabel(format:hours == 168 ? .dateTime.weekday(.abbreviated) :
                                                          .dateTime.day().hour())
                    }
                }
                .frame(height:155)
                Text("Barras: acumulación prevista por hora (mm). El detalle y la incertidumbre dependen del plazo.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let weather {
                ForEach(weather.days) { day in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                                .font(.subheadline.bold())
                            Spacer()
                            Text(String(format:"%.1f mm",day.totalMM))
                                .font(.subheadline.bold())
                                .foregroundStyle(RainVisual.color(day.totalMM))
                            Text("\(day.probability)%")
                                .font(.caption).foregroundStyle(.secondary)
                            if let low=day.minTemperature,let high=day.maxTemperature {
                                Text("\(Int(low.rounded()))–\(Int(high.rounded()))°")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        let spans=RainInsight.dailyPeriods(weather,day:day.date)
                        if spans.isEmpty {
                            Text("No se esperan franjas con lluvia apreciable")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(spans.prefix(4))) { period in
                                HStack(spacing:8) {
                                    Circle().fill(RainVisual.color(period.peakMMH))
                                        .frame(width:7,height:7)
                                    Text(period.label)
                                        .font(.subheadline.monospacedDigit())
                                    Spacer()
                                    Text(RainVisual.intensity(period.peakMMH))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(String(format:"%.1f mm",period.accumulationMM))
                                        .font(.caption.bold())
                                }
                            }
                        }
                    }
                    .padding(11)
                    .background(.white.opacity(0.055),in:RoundedRectangle(cornerRadius:12))
                }
                Text("Franjas horarias calculadas con el modelo horario de Open-Meteo. Son orientativas, especialmente después del segundo día.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
    }
}

struct PastRainView:View {
    @ObservedObject var store:RainStore
    private var hours:[HourlyRain] {
        let now=Date()
        return store.snapshot?.hours.filter {
            $0.time >= now.addingTimeInterval(-24*3600) && $0.time <= now
        } ?? []
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Lluvia · últimas 24 horas",systemImage:"clock.arrow.circlepath")
                .font(.headline)
            if !hours.isEmpty {
                Chart {
                    ForEach(hours) { hour in
                        BarMark(x:.value("Hora",hour.time),
                                y:.value("Milímetros estimados",hour.millimeters))
                            .foregroundStyle(RainVisual.color(hour.millimeters))
                    }
                    ForEach(store.reports.filter {
                        $0.date >= Date().addingTimeInterval(-24*3600) &&
                        RainFeedback.near($0,latitude:store.coordinate.latitude,
                                          longitude:store.coordinate.longitude)
                    },id:\.date) { report in
                        RuleMark(x:.value("Tu observación",report.date))
                            .foregroundStyle(report.raining ? .red:.mint)
                            .lineStyle(StrokeStyle(lineWidth:2,dash:[3,2]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values:.stride(by:.hour,count:4)) { _ in
                        AxisValueLabel(format:.dateTime.hour().minute())
                    }
                }
                .frame(height:140)
                Text("Milímetros horarios estimados por Open-Meteo; no son una medición en tu punto. Rojo: indicaste lluvia; verde: indicaste seco.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Historial horario pendiente").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(LinearGradient(colors:[.purple.opacity(0.22),.cyan.opacity(0.10)],
            startPoint:.topLeading,endPoint:.bottomTrailing),
            in:RoundedRectangle(cornerRadius:20))
    }
}
