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

private struct RainMinuteBars:View {
    let data:[RainMinuteBar]
    let horizon:Int
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
                            Button {
                                selectedMinute=point.minute
                            } label:{
                                RoundedRectangle(cornerRadius:1.5)
                                    .fill(point.mmh == nil ? Color.gray.opacity(0.22) :
                                          point.wet ? RainVisual.color(point.mmh ?? 0) :
                                          Color.gray.opacity(0.25))
                                    .frame(width:barWidth,height:barHeight(point))
                                    .overlay(alignment:.top) {
                                        if selectedMinute==point.minute {
                                            Rectangle().stroke(.white,lineWidth:1.5)
                                        }
                                    }
                                    .frame(width:barWidth,height:105,alignment:.bottom)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Minuto \(point.minute), " +
                                (point.mmh.map{String(format:"%.1f milímetros por hora",$0)}
                                  ?? "sin dato"))
                            .id(point.minute)
                        }
                    }
                    HStack(spacing:0) {
                        ForEach(0...horizon/10,id:\.self) { i in
                            Text(i == 0 ? "Ahora" : "+\(i*10)")
                                .font(.system(size:10,weight:.medium,design:.rounded))
                                .foregroundStyle(.secondary)
                                .frame(width:CGFloat(i==0 ? 10 : 10)*(barWidth+spacing),
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
            let rows=RainPulseFusion.points(samples:store.snapshot?.samples ?? [],
                                        models:store.shortModels,now:now,horizon:horizon)
            let bars=rows.map { RainMinuteBar(minute:$0.minute,mmh:$0.rateMMH) }
            if bars.isEmpty {
                ContentUnavailableView("Sin previsión local",systemImage:"cloud.slash",
                    description:Text("Actualiza la previsión de este lugar."))
                    .frame(height:125)
            } else {
                let selected=rows.min(by:{
                    abs($0.minute-(selectedMinute ?? 0)) <
                    abs($1.minute-(selectedMinute ?? 0))
                }) ?? rows[0]
                let isRaining=store.snapshot?.isRaining ?? false
                Text(RainBarDisplay.summary(bars,rainingNow:isRaining))
                    .font(.subheadline.bold())
                    .foregroundStyle(.cyan)
                    .fixedSize(horizontal:false,vertical:true)
                HStack(alignment:.firstTextBaseline) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(selectedMinute == nil ? "Ahora" : "En +\(selected.minute) min")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(RainVisual.intensity(selected.rateMMH))
                            .font(.title3.bold())
                            .foregroundStyle(RainVisual.color(selected.rateMMH))
                    }
                    Spacer()
                    Text(String(format:"%.1f mm/h",selected.rateMMH))
                        .font(.title3.bold().monospacedDigit())
                }
                RainMinuteBars(data:bars,horizon:horizon,
                               selectedMinute:$selectedMinute)
                HStack(spacing:6) {
                    Text("Gris: sin lluvia")
                    Spacer()
                    Text("Color: intensidad")
                    Spacer()
                    Image(systemName:"hand.draw").foregroundStyle(.secondary)
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text("Desliza las barras para ver los \(horizon) minutos. " +
                     "Cada minuto es una posición visual derivada de los intervalos de la fuente.")
                    .font(.caption2).foregroundStyle(.secondary)

                Button {
                    withAnimation {showModels.toggle()}
                } label:{
                    HStack {
                        Label(showModels ? "Ocultar comparación" : "Comparar cada modelo",
                              systemImage:"square.stack.3d.up")
                        Spacer(minLength:4)
                        Text("\(store.shortModels.count) fuentes")
                            .font(.caption2).foregroundStyle(.secondary)
                        Image(systemName:showModels ? "chevron.up":"chevron.down")
                    }
                    .font(.subheadline.bold())
                }
                .buttonStyle(.plain)
                if showModels {
                    VStack(alignment:.leading,spacing:9) {
                        Text("Cada modelo tiene sus propias barras. Sus datos son horarios; " +
                             "las barras intermedias repiten la estimación de esa hora.")
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(store.shortModels,id:\.name) { model in
                            RainModelBarDisclosure(model:model,now:now,horizon:horizon)
                        }
                        if store.shortModels.isEmpty {
                            Text(store.shortModelsLoading ? "Consultando modelos…" :
                                 "Ahora solo está disponible la previsión principal.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(15)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
    }
}

private struct RainModelBarDisclosure:View {
    let model:RainShortModel
    let now:Date
    let horizon:Int
    @State private var open=false
    @State private var selectedMinute:Int?

    private var bars:[RainMinuteBar] {
        (0...horizon).map { minute in
            RainMinuteBar(minute:minute,
              mmh:model.rateMMH(at:now.addingTimeInterval(Double(minute*60))))
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Button {
                withAnimation {open.toggle()}
            } label:{
                HStack(spacing:7) {
                    Image(systemName:open ? "chevron.down":"chevron.right")
                        .foregroundStyle(.cyan)
                    VStack(alignment:.leading,spacing:3) {
                        Text(model.name).font(.subheadline.bold())
                        Text(RainBarDisplay.summary(bars,rainingNow:bars.first?.wet ?? false))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength:8)
                    Text(model.rateMMH(at:now).map {String(format:"%.1f",$0)}
                         ?? "—")
                        .font(.subheadline.monospacedDigit().bold())
                    Text("mm/h").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if open {
                let selected=bars.first(where:{$0.minute==selectedMinute}) ?? bars[0]
                HStack {
                    Text(selectedMinute == nil ? "Ahora" : "+\(selected.minute) min")
                    Spacer()
                    Text(selected.mmh.map{String(format:"%.1f mm/h",$0)} ?? "Sin dato")
                }
                .font(.caption).foregroundStyle(.secondary)
                RainMinuteBars(data:bars,horizon:horizon,
                               selectedMinute:$selectedMinute)
            }
        }
        .padding(10)
        .background(.white.opacity(0.055),in:RoundedRectangle(cornerRadius:12))
    }
}

struct ThreeHourRainView: View {
    let weather:RainSnapshot?
    let models:[RainShortModel]
    @State private var chosen:Int=0

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Próximas 3 horas",systemImage:"chart.bar.fill")
                .font(.headline)
            if let weather {
                let overview=RainPulseFusion.points(samples:weather.samples,
                                    models:models,now:Date(),horizon:120,step:15)
                if let note=RainPulseFusion.summary(overview) {
                    Text("Primeras 2 h · " + note)
                        .font(.caption2).foregroundStyle(.cyan)
                }

                let slots=RainInsight.moments(samples:weather.samples,from:.now,minutes:180,step:15)
                if slots.isEmpty {
                    Text("No hay datos de 15 min para las próximas horas")
                        .foregroundStyle(.secondary)
                } else {
                    let selected=slots.min(by:{ abs($0.minute-chosen)<abs($1.minute-chosen) }) ?? slots[0]
                    HStack(spacing:6) {
                        Text(selected.date.formatted(date:.omitted,time:.shortened))
                            .font(.subheadline.bold())
                        Spacer()
                        Text(String(format:"%.1f mm/h",selected.rateMMH))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(RainVisual.color(selected.rateMMH))
                        Text(selected.probability.map{"\($0)%"} ?? "—")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    GeometryReader { geometry in
                        let barWidth=max(4,(geometry.size.width-CGFloat(slots.count-1)*5)/CGFloat(slots.count))
                        let peak=max(0.7,slots.map(\.rateMMH).max() ?? 0)
                        HStack(alignment:.bottom,spacing:5) {
                            ForEach(slots) { point in
                                Button {chosen=point.minute} label:{
                                    VStack(spacing:5) {
                                        Spacer(minLength:0)
                                        RoundedRectangle(cornerRadius:3)
                                            .fill(RainVisual.color(point.rateMMH))
                                            .frame(height:max(point.rateMMH>0.1 ? 6:2,
                                                              CGFloat(point.rateMMH/peak)*120))
                                            .overlay(alignment:.top) {
                                                if chosen==point.minute {
                                                    RoundedRectangle(cornerRadius:3)
                                                        .stroke(.white,lineWidth:1.5)
                                                }
                                            }
                                        Text(point.minute%30==0 ? "+\(point.minute)" : " ")
                                            .font(.system(size:9))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                            .frame(height:15)
                                    }
                                    .frame(width:barWidth)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("+\(point.minute) min: \(String(format:"%.1f",point.rateMMH)) mm/h")
                            }
                        }
                    }
                    .frame(height:155)
                    RainIntensityLegend()
                    HStack {
                        let wet=slots.filter{$0.rateMMH>=RainInsight.wetRate}.count
                        Label("~\(wet*15) min con lluvia",systemImage:"clock")
                        Spacer()
                        Text("Modelo 15 min")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
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
