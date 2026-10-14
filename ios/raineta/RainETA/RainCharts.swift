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
                RainPulsePlot(points:samples,horizon:horizon,selectedMinute:$selectedMinute)
                    .frame(height:188)
                    .clipped()
                HStack {
                    Text("Ahora")
                    Spacer()
                    Text("+\(horizon/2) min")
                    Spacer()
                    Text("+\(horizon) min")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                RainIntensityLegend()
                if selected.usesModelMedian {
                    HStack(spacing:12) {
                        Label("Mediana modelos",systemImage:"line.diagonal")
                            .foregroundStyle(.cyan)
                        Label("Modelo automático 15 min",systemImage:"line.diagonal")
                            .foregroundStyle(.mint)
                    }
                    .font(.caption2)
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
                    if !store.shortModels.isEmpty {
                        VStack(alignment:.leading,spacing:12) {
                            HStack {
                                Text("Precipitación por modelo")
                                    .font(.caption.bold())
                                Spacer()
                                Text("mm/h · valor horario")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            ForEach(Array(store.shortModels.enumerated()),id:\.offset) { i,model in
                                RainPulseModelRow(model:model,now:now,horizon:horizon,
                                    color:[Color.cyan,.mint,.orange,.purple,.pink][i % 5])
                            }
                            if let note=RainPulseFusion.summary(samples) {
                                Label(note,systemImage:"info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top,4)
                    } else if store.shortModelsLoading {
                        ProgressView("Consultando modelos…")
                    } else {
                        Text("No hay modelos suficientes. Continúa el Pulso automático.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Paso visual: 1 min. Los modelos usan acumulados horarios; " +
                     "las curvas por minuto NO son predicciones meteorológicas independientes cada minuto. " +
                     "La estimación del radar se calcula por separado.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
    }
}


private struct RainPulsePlot: View {
    let points:[RainPulseMinute]
    let horizon:Int
    @Binding var selectedMinute:Int?

    var body:some View {
        Canvas { context,canvas in
            guard !points.isEmpty, canvas.width>1,canvas.height>1 else {return}
            let top=12.0, bottom=canvas.height-8
            let maxRain=max(0.6,(points.map(\.highMMH).max() ?? 0)*1.1,
                            (points.compactMap(\.automaticMMH).max() ?? 0)*1.1)
            func pos(_ minute:Int,_ rain:Double) -> CGPoint {
                CGPoint(x:canvas.width*CGFloat(minute)/CGFloat(max(1,horizon)),
                        y:bottom-(bottom-top)*CGFloat(max(0,rain)/maxRain))
            }
            for i in 0...3 {
                let y=top+(bottom-top)*CGFloat(i)/3
                var grid=Path()
                grid.move(to:CGPoint(x:0,y:y))
                grid.addLine(to:CGPoint(x:canvas.width,y:y))
                context.stroke(grid,with:.color(.white.opacity(0.10)),lineWidth:1)
            }
            let envelope=points.filter(\.usesModelMedian)
            if envelope.count>1 {
                var area=Path()
                area.move(to:pos(envelope[0].minute,envelope[0].highMMH))
                for p in envelope.dropFirst() {
                    area.addLine(to:pos(p.minute,p.highMMH))
                }
                for p in envelope.reversed() {
                    area.addLine(to:pos(p.minute,p.lowMMH))
                }
                area.closeSubpath()
                context.fill(area,with:.color(.cyan.opacity(0.15)))
            }
            var consensus=Path()
            var hasFirst=false
            for p in points {
                if !hasFirst {
                    consensus.move(to:pos(p.minute,p.rateMMH))
                    hasFirst=true
                } else {
                    consensus.addLine(to:pos(p.minute,p.rateMMH))
                }
            }
            context.stroke(consensus,with:.color(.cyan),
                           style:StrokeStyle(lineWidth:2.5,lineCap:.round,lineJoin:.round))
            var original=Path()
            var started=false
            for p in points {
                if let value=p.automaticMMH {
                    if !started {
                        original.move(to:pos(p.minute,value))
                        started=true
                    } else {
                        original.addLine(to:pos(p.minute,value))
                    }
                } else {started=false}
            }
            if envelope.count>1 {
                context.stroke(original,with:.color(.mint),
                               style:StrokeStyle(lineWidth:1.7,dash:[4,4]))
            }
            if let selectedMinute,let point=points.min(by:{
                abs($0.minute-selectedMinute)<abs($1.minute-selectedMinute)
            }) {
                let x=pos(point.minute,point.rateMMH).x
                var cursor=Path()
                cursor.move(to:CGPoint(x:x,y:0))
                cursor.addLine(to:CGPoint(x:x,y:canvas.height))
                context.stroke(cursor,with:.color(.white.opacity(0.7)),
                               style:StrokeStyle(lineWidth:1,dash:[3,4]))
                let center=pos(point.minute,point.rateMMH)
                context.fill(Path(ellipseIn:CGRect(x:center.x-3,y:center.y-3,
                                                   width:6,height:6)),
                             with:.color(.white))
            }
        }
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:0).onChanged { value in
                        selectedMinute = max(0,min(horizon,
                            Int((value.location.x/max(1,geometry.size.width) *
                                 CGFloat(horizon)).rounded())))
                    })
            }
        }
        .accessibilityLabel("Previsión de lluvia de los próximos \(horizon) minutos")
    }
}

private struct RainPulseModelRow:View {
    let model:RainShortModel
    let now:Date
    let horizon:Int
    let color:Color
    private var steps:[RainPulseModelMinute] {
        RainPulseFusion.individual(models:[model],now:now,horizon:horizon,step:5)
    }
    var body:some View {
        let points=steps
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(model.name).font(.subheadline.bold())
                Spacer()
                Text(model.rateMMH(at:now).map {String(format:"Ahora %.1f mm/h",$0)}
                     ?? "Sin dato actual")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Canvas {context,size in
                let ymax=max(0.4,(points.map(\.mmh).max() ?? 0)*1.15)
                var path=Path()
                for (i,p) in points.enumerated() {
                    let xy=CGPoint(x:size.width*CGFloat(p.minute)/CGFloat(max(1,horizon)),
                                   y:size.height-3-(size.height-8)*CGFloat(p.mmh/ymax))
                    if i==0 {path.move(to:xy)}
                    else {path.addLine(to:xy)}
                }
                context.stroke(path,with:.color(color),
                               style:StrokeStyle(lineWidth:2.2,lineCap:.round,lineJoin:.round))
            }
            .frame(height:36)
            .clipped()
            HStack {
                Text("Ahora")
                Spacer()
                Text("+\(horizon) min")
                Spacer()
                Text("Pico \(String(format:"%.1f",points.map(\.mmh).max() ?? 0))")
            }
            .font(.system(size:10,design:.rounded)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.white.opacity(0.055),in:RoundedRectangle(cornerRadius:11))
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
