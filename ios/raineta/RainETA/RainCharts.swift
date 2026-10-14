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

struct MinuteRainGraph: View {
    @ObservedObject var store: RainStore
    @AppStorage("raineta.settings.defaultHorizon") private var horizon = 60
    @State private var selectedMinute: Int?
    @State private var compareExpanded = false

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Pulso de lluvia",systemImage:"waveform.path")
                    .font(.headline)
                Spacer()
                Text("MINUTO A MINUTO")
                    .font(.system(size:9,weight:.bold))
                    .foregroundStyle(.cyan)
            }
            Picker("Horizonte",selection:$horizon) {
                Text("30 min").tag(30)
                Text("60 min").tag(60)
                Text("120 min").tag(120)
            }
            .pickerStyle(.segmented)
            let now=Date()
            let samples=RainPulseFusion.points(
                samples:store.snapshot?.samples ?? [],
                models:store.shortModels,now:now,horizon:horizon)
            if samples.isEmpty {
                ContentUnavailableView("Sin datos suficientes",systemImage:"cloud.slash",
                    description:Text("Actualiza la previsión o cambia de localidad."))
                    .frame(height:145)
            } else {
                let selected=samples.min(by:{
                    abs($0.minute-(selectedMinute ?? 0)) <
                    abs($1.minute-(selectedMinute ?? 0))
                }) ?? samples[0]
                HStack(alignment:.firstTextBaseline) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(selectedMinute == nil ? "Ahora" : "Dentro de \(selected.minute) min")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(RainVisual.intensity(selected.rateMMH))
                            .font(.title3.bold())
                            .foregroundStyle(RainVisual.color(selected.rateMMH))
                    }
                    Spacer()
                    VStack(alignment:.trailing,spacing:3) {
                        Text(String(format:"%.1f mm/h",selected.rateMMH))
                            .font(.headline.monospacedDigit())
                        Text(selected.usesModelMedian ?
                             "\(selected.rainyModels)/\(selected.availableModels) modelos prevén lluvia" :
                             "Previsión automática")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Chart(samples) { point in
                    if point.usesModelMedian {
                        AreaMark(x:.value("Minuto",point.minute),
                                 yStart:.value("Mínimo",point.lowMMH),
                                 yEnd:.value("Máximo",point.highMMH))
                            .foregroundStyle(.cyan.opacity(0.17))
                            .interpolationMethod(.stepEnd)
                    }
                    LineMark(x:.value("Minuto",point.minute),
                             y:.value("mm/h",point.rateMMH))
                        .foregroundStyle(.cyan)
                        .lineStyle(StrokeStyle(lineWidth:2.6))
                        .interpolationMethod(point.usesModelMedian ? .stepEnd : .linear)
                }
                .chartXScale(domain:0...horizon)
                .chartYScale(domain:0...max(0.6,(samples.map(\.highMMH).max() ?? 0)*1.1))
                .chartXAxis {
                    AxisMarks(values:stride(from:0,through:horizon,
                                            by:horizon==30 ? 5 : horizon==60 ? 10 : 20).map{$0}) { axis in
                        AxisValueLabel {
                            if let minute=axis.as(Int.self) { Text("+\(minute)") }
                        }
                        AxisTick()
                    }
                }
                .chartYSelection(value:.constant(nil as Double?))
                .chartXSelection(value:$selectedMinute)
                .frame(height:172)
                RainIntensityLegend()
                if selected.usesModelMedian {
                    HStack {
                        Text("Consenso de \(selected.availableModels) modelos · franja: " +
                             String(format:"%.1f–%.1f mm/h",selected.lowMMH,selected.highMMH))
                        Spacer(minLength:0)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                if let estimate=store.shortEstimate,estimate.isUsable(at:now),
                   estimate.radarBased {
                    Label("Radar de llegada activo · " + estimate.confidence,
                          systemImage:"dot.radiowaves.left.and.right")
                        .font(.caption2).foregroundStyle(.cyan)
                }
                Button {
                    withAnimation {compareExpanded.toggle()}
                } label:{
                    HStack {
                        Label(compareExpanded ? "Ocultar modelos" : "Ver modelos individuales",
                              systemImage:"square.stack.3d.up")
                        Spacer()
                        Text("\(store.shortModels.count) disponibles")
                            .font(.caption2).foregroundStyle(.secondary)
                        Image(systemName:compareExpanded ? "chevron.up":"chevron.down")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                if compareExpanded {
                    let curves=RainPulseFusion.individual(models:store.shortModels,
                                                         now:now,horizon:horizon)
                    if !curves.isEmpty {
                        Chart(curves) { item in
                            LineMark(x:.value("Minuto",item.minute),
                                     y:.value("mm/h",item.mmh))
                                .foregroundStyle(by:.value("Modelo",item.name))
                                .interpolationMethod(.stepEnd)
                        }
                        .chartXScale(domain:0...horizon)
                        .chartYAxis { AxisMarks(position:.leading) }
                        .chartLegend(.visible)
                        .frame(height:220)
                        if let note=RainPulseFusion.summary(samples) {
                            Text(note)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if store.shortModelsLoading {
                        ProgressView("Consultando modelos…")
                    } else {
                        Text("No hay modelos suficientes. Continúa el Pulso automático.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Paso visual: 1 min. Los modelos usan acumulados horarios; " +
                     "la curva por minuto NO es una previsión nativa por minuto. " +
                     "La estimación del radar se calcula por separado.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
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
