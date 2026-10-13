import SwiftUI
import Charts

enum RainSpanishDates {
    static let locale=Locale(identifier:"es_ES")
    static func day(_ date:Date) -> String {
        date.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).locale(locale))
            .replacingOccurrences(of:".",with:"")
            .capitalized(with:locale)
    }
    static func long(_ date:Date) -> String {
        date.formatted(Date.FormatStyle().weekday(.wide).day().month(.wide).locale(locale))
            .capitalized(with:locale)
    }
}

struct RainWeekForecast: View {
    let weather:RainSnapshot?
    @State private var selectedDay:Date?
    private var temperatureBounds:(min:Double,max:Double) {
        guard let days=weather?.days else{return (0,30)}
        let lo=days.compactMap(\.minTemperature).min() ?? 0
        let hi=days.compactMap(\.maxTemperature).max() ?? 30
        return (lo-1,max(lo+5,hi+1))
    }

    var body:some View {
        VStack(alignment:.leading,spacing:13) {
            HStack {
                Label("Semana meteorológica",systemImage:"calendar")
                    .font(.headline)
                Spacer()
                Text("7 días").font(.caption.bold()).foregroundStyle(.cyan)
            }
            if let weather {
                Text("Temperaturas, probabilidad y lluvia prevista en un vistazo. Pulsa un día para ver las horas.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing:8) {
                    ForEach(weather.days) { day in
                        Button {selectedDay=day.date} label:{
                            HStack(spacing:8) {
                                Text(RainSpanishDates.day(day.date))
                                    .font(.system(size:11,weight:.bold))
                                    .frame(width:70,alignment:.leading)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                Image(systemName:day.totalMM>=0.1 ? "cloud.rain.fill":"sun.max.fill")
                                    .foregroundStyle(day.totalMM>=0.1 ? .cyan:.yellow)
                                    .frame(width:20)
                                VStack(alignment:.leading,spacing:4) {
                                    if day.totalMM>=0.1 || day.probability>=20 {
                                        Text("\(day.probability)% · \(String(format:"%.1f",day.totalMM)) mm")
                                            .font(.system(size:10,weight:.medium))
                                            .foregroundStyle(.cyan)
                                    } else {
                                        Text("Sin lluvia destacable")
                                            .font(.system(size:10))
                                            .foregroundStyle(.secondary)
                                    }
                                    GeometryReader { geometry in
                                        let low=day.minTemperature ?? temperatureBounds.min
                                        let high=day.maxTemperature ?? low
                                        let range=max(1,temperatureBounds.max-temperatureBounds.min)
                                        let start=max(0,(low-temperatureBounds.min)/range)
                                        let proportion=max(0.015,(high-low)/range)
                                        Capsule().fill(.white.opacity(0.10))
                                            .frame(height:12)
                                            .overlay(alignment:.leading) {
                                                Capsule()
                                                    .fill(LinearGradient(
                                                        colors:[.cyan,.yellow,.orange],
                                                        startPoint:.leading,endPoint:.trailing))
                                                    .frame(width:max(5,CGFloat(proportion)*geometry.size.width),
                                                           height:12)
                                                    .offset(x:CGFloat(start)*geometry.size.width)
                                            }
                                    }
                                    .frame(height:12)
                                }
                                Text(day.minTemperature.map{"\(Int($0.rounded()))°"} ?? "—")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width:26,alignment:.trailing)
                                Text(day.maxTemperature.map{"\(Int($0.rounded()))°"} ?? "—")
                                    .font(.caption.bold().monospacedDigit())
                                    .frame(width:26,alignment:.trailing)
                            }
                            .frame(minHeight:52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if day.id != weather.days.last?.id {
                            Divider().overlay(.white.opacity(0.04))
                        }
                    }
                }
                Text("Las barras horizontales muestran mínimas y máximas con una escala común. Lluvia en mm y posibilidad máxima diaria (%); no son medidas equivalentes.")
                    .font(.caption2).foregroundStyle(.secondary)
                Divider()
                ForEach(weather.days) { day in
                    let isToday=Calendar.current.isDateInToday(day.date)
                    let episodes=RainInsight.dailyPeriods(weather,day:day.date)
                        .filter { !isToday || $0.end > Date() }
                    VStack(alignment:.leading,spacing:6) {
                        HStack {
                            Text(RainSpanishDates.day(day.date))
                                .font(.subheadline.bold())
                            Spacer()
                            Text(String(format:"%.1f mm · %d%%",day.totalMM,day.probability))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if episodes.isEmpty {
                            Text("Sin franjas de lluvia previstas \(isToday ? "para lo que queda del día" : "para este día")")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(episodes.prefix(5))) { period in
                                HStack {
                                    Circle().fill(RainVisual.color(period.peakMMH))
                                        .frame(width:7,height:7)
                                    Text(period.label)
                                        .font(.caption.monospacedDigit())
                                    Spacer()
                                    Text(String(format:"%.1f mm",period.accumulationMM))
                                        .font(.caption).foregroundStyle(.cyan)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:12))
                }
            } else {
                ProgressView("Consultando la previsión semanal…")
            }
        }
        .padding(15)
        .background(.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
        .sheet(item:Binding<RainWeekSelection?>(
            get:{selectedDay.map{RainWeekSelection(date:$0)}},
            set:{selectedDay=$0?.date}
        )) { selection in
            if let weather,
               let day=weather.days.first(where:{Calendar.current.isDate($0.date,inSameDayAs:selection.date)}) {
                RainDayDetail(weather:weather,day:day)
            }
        }
    }
}

struct RainWeekSelection:Identifiable {
    let date:Date
    var id:Date{date}
}

struct RainDayDetail:View {
    let weather:RainSnapshot
    let day:DailyRain
    @Environment(\.dismiss) private var dismiss
    private var rows:[HourlyRain] {
        weather.hours.filter{Calendar.current.isDate($0.time,inSameDayAs:day.date)}
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    HStack {
                        Image(systemName:day.totalMM>=0.1 ? "cloud.rain.fill":"sun.max.fill")
                            .font(.system(size:46))
                            .foregroundStyle(day.totalMM>=0.1 ? .cyan:.yellow)
                        VStack(alignment:.leading,spacing:5) {
                            Text(RainSpanishDates.long(day.date))
                                .font(.title3.bold())
                            HStack {
                                Text(String(format:"%.1f mm",day.totalMM))
                                    .font(.title2.bold()).foregroundStyle(.cyan)
                                Text("\(day.probability)% prob. máxima")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            if let low=day.minTemperature,let high=day.maxTemperature {
                                Text("Mínima \(Int(low.rounded()))° · Máxima \(Int(high.rounded()))°")
                                    .font(.subheadline)
                            }
                        }
                    }
                    if !rows.isEmpty {
                        Text("Cantidad de lluvia por hora").font(.headline)
                        Chart(rows) { row in
                            BarMark(x:.value("Hora",row.time),
                                    y:.value("mm/hora",row.millimeters))
                                .foregroundStyle(RainVisual.color(row.millimeters))
                        }
                        .chartXAxis {
                            AxisMarks(values:.stride(by:.hour,count:3)) {
                                AxisValueLabel(format:.dateTime.hour())
                            }
                        }
                        .frame(height:180)
                        Text("Probabilidad prevista por hora").font(.headline)
                        Chart(rows) { row in
                            LineMark(x:.value("Hora",row.time),
                                     y:.value("Porcentaje",row.probability))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(.cyan)
                            AreaMark(x:.value("Hora",row.time),
                                     y:.value("Porcentaje",row.probability))
                                .foregroundStyle(.cyan.opacity(0.13))
                        }
                        .chartYScale(domain:0...100)
                        .chartXAxis {
                            AxisMarks(values:.stride(by:.hour,count:3)) {
                                AxisValueLabel(format:.dateTime.hour())
                            }
                        }
                        .frame(height:160)
                        Text("Períodos de precipitación")
                            .font(.headline)
                        ForEach(RainInsight.dailyPeriods(weather,day:day.date)) { period in
                            HStack {
                                Label(period.label,systemImage:"cloud.rain")
                                    .foregroundStyle(.cyan)
                                Spacer()
                                Text(String(format:"%.1f mm",period.accumulationMM))
                            }
                            .font(.subheadline)
                        }
                        Text("Fuente: Open-Meteo, selección automática de modelos. Valores horarios previstos y sujetos a cambios; probabilidad y cantidad no son lo mismo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(Color(red:0.035,green:0.067,blue:0.12))
            .navigationTitle("Detalle del día")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) {
                Button("Cerrar"){dismiss()}
            }}
        }
        .preferredColorScheme(.dark)
    }
}
