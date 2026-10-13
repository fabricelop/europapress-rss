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
    let projection: RadarProjection?
    let weather: RainSnapshot?
    @AppStorage("raineta.settings.defaultHorizon") private var horizon = 60
    @State private var selectedMinute: Int?
    private var rows:[RainMoment] {
        guard let weather else { return [] }
        return RainInsight.moments(samples:weather.samples,from:.now,minutes:horizon,step:1)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:13) {
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
            let samples=rows
            if samples.isEmpty {
                ContentUnavailableView("Sin datos suficientes",systemImage:"cloud.slash",
                    description:Text("Actualiza la previsión o cambia de localidad."))
                    .frame(height:160)
            } else {
                let current=samples.min(by:{ abs($0.minute-(selectedMinute ?? 0)) <
                                               abs($1.minute-(selectedMinute ?? 0)) }) ?? samples[0]
                HStack(alignment:.firstTextBaseline) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(selectedMinute == nil ? "En este momento" : "Dentro de \(current.minute) min")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(RainVisual.intensity(current.rateMMH))
                            .font(.title3.bold())
                            .foregroundStyle(RainVisual.color(current.rateMMH))
                    }
                    Spacer()
                    VStack(alignment:.trailing,spacing:4) {
                        Text(String(format:"%.1f mm/h",current.rateMMH))
                            .font(.headline.monospacedDigit())
                        Text(current.probability.map { "\($0)% prob." } ?? "Prob. no disponible")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Chart(samples) { point in
                    BarMark(x:.value("Minuto",point.minute),
                            y:.value("mm/h",point.rateMMH),
                            width:.fixed(horizon == 30 ? 7 : horizon == 60 ? 4 : 2))
                        .foregroundStyle(RainVisual.color(point.rateMMH))
                        .cornerRadius(2)
                }
                .chartXScale(domain:0...horizon)
                .chartYScale(domain:0...max(0.6,(samples.map(\.rateMMH).max() ?? 0) * 1.15))
                .chartXAxis {
                    AxisMarks(values:stride(from:0,through:horizon,by:horizon == 30 ? 5 : horizon == 60 ? 10 : 20).map{$0}) { axis in
                        AxisValueLabel {
                            if let minute=axis.as(Int.self) { Text("+\(minute)") }
                        }
                        AxisTick()
                    }
                }
                .chartYAxis {
                    AxisMarks(position:.leading)
                }
                .chartXSelection(value:$selectedMinute)
                .frame(height:172)
                RainIntensityLegend()
                HStack {
                    Label("Máximo \(String(format:"%.1f",samples.map(\.rateMMH).max() ?? 0)) mm/h",
                          systemImage:"drop.fill")
                    Spacer()
                    let wet=samples.filter{$0.rateMMH >= RainInsight.wetRate}.count
                    Text("\(wet) min con señal de lluvia")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.cyan)
            }
        }
        .padding(15)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
    }
}

struct ThreeHourRainView: View {
    let weather:RainSnapshot?
    @State private var chosen:Int=0

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Próximas 3 horas",systemImage:"chart.bar.fill")
                .font(.headline)
            if let weather {
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
