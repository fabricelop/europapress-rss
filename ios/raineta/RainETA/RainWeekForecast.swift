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
    let radarAvailable:Bool
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
                if radarAvailable {
                    Label("El radar ajusta las próximas 2 horas en Pulso y en 3 horas. " +
                          "Los totales de los 7 días siguen siendo previsiones de modelos.",
                          systemImage:"dot.radiowaves.left.and.right")
                        .font(.caption2).foregroundStyle(.cyan)
                }
                VStack(spacing:8) {
                    ForEach(weather.days) { day in
                        Button {selectedDay=day.date} label:{
                            HStack(spacing:8) {
                                Text(RainSpanishDates.day(day.date))
                                    .font(.system(size:11,weight:.bold))
                                    .frame(width:66,alignment:.leading)
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
                                    .font(.system(size:13,weight:.regular,design:.rounded))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal:true,vertical:false)
                                    .lineLimit(1)
                                    .frame(width:36,alignment:.trailing)
                                Text(day.maxTemperature.map{"\(Int($0.rounded()))°"} ?? "—")
                                    .font(.system(size:13,weight:.bold,design:.rounded))
                                    .fixedSize(horizontal:true,vertical:false)
                                    .lineLimit(1)
                                    .frame(width:36,alignment:.trailing)
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
                Text("Toca un día para ver horas, lluvia y probabilidad.")
                    .font(.caption2).foregroundStyle(.secondary)
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
        let start=Calendar.current.startOfDay(for:day.date)
        let end=Calendar.current.date(byAdding:.day,value:1,to:start) ?? start.addingTimeInterval(86400)
        return weather.hours.filter{$0.time>start && $0.time<=end}
            .sorted{$0.time<$1.time}
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
                            BarMark(x:.value("Hora",RainInsight.hourlyStart(row.time)),
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
                            LineMark(x:.value("Hora",RainInsight.hourlyStart(row.time)),
                                     y:.value("Porcentaje",row.probability))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(.cyan)
                            AreaMark(x:.value("Hora",RainInsight.hourlyStart(row.time)),
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
                        if RainInsight.precipitationUncertainty(hours:weather.hours,day:day.date) {
                            Label("Probabilidad y cantidad discrepan: previsión incierta",
                                  systemImage:"exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text("Precipitación: hora anterior · Open-Meteo")
                            .font(.caption2).foregroundStyle(.secondary)
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
