import SwiftUI
import Charts

struct MinuteRainGraph: View {
    let projection: RadarProjection?
    let weather: RainSnapshot?
    @State private var horizon = 60

    private var radarRows: [RadarMinute] {
        projection?.minutePoints.filter { $0.minute <= horizon } ?? []
    }
    private var modelRows: [RadarMinute] {
        guard let wx = weather else { return [] }
        let now = Date()
        let source = wx.samples.sorted { $0.time < $1.time }
        if source.isEmpty { return [] }
        return (0...horizon).map { minute in
            let target = now.addingTimeInterval(Double(minute * 60))
            let lower = source.last { $0.time <= target } ?? source[0]
            let upper = source.first { $0.time >= target } ?? source[source.count - 1]
            let range = upper.time.timeIntervalSince(lower.time)
            let blend = range > 0 ? min(1, max(0, target.timeIntervalSince(lower.time) / range)) : 0
            let mm15 = lower.precipitation * (1-blend) + upper.precipitation * blend
            // Relative intensity for a chart, not independent minute observations.
            return RadarMinute(minute: minute, signal: min(1, max(0, mm15 / 2.0)), confidence: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Lluvia minuto a minuto", systemImage: "chart.xyaxis.line")
                .font(.headline)
            Picker("Horizonte", selection: $horizon) {
                Text("30 min").tag(30)
                Text("60 min").tag(60)
                Text("120 min").tag(120)
            }
            .pickerStyle(.segmented)

            let rows = projection == nil ? modelRows : radarRows
            if rows.isEmpty {
                ContentUnavailableView("Sin datos de corto plazo",
                                       systemImage: "cloud.slash",
                                       description: Text("Actualiza para obtener radar o pronóstico."))
                    .frame(height: 180)
            } else {
                Chart(rows) { point in
                    BarMark(x: .value("Minuto", point.minute),
                            y: .value("Señal", max(0, point.signal * 100)), width: .fixed(2))
                        .foregroundStyle(point.signal > 0.65 ? Color.indigo :
                                         point.signal > 0.25 ? Color.blue : Color.cyan)
                }
                .chartXScale(domain: 0...horizon)
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: stride(from: 0, through: horizon, by: horizon >= 120 ? 30 : 15).map { $0 }) { axis in
                        AxisValueLabel {
                            if let minute = axis.as(Int.self) { Text("+\(minute)m") }
                        }
                        AxisTick()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100])
                }
                .frame(height: 160)
                Text(projection == nil
                     ? "Modelo interpolado cada minuto desde intervalos de 15 min. No son observaciones ni predicciones independientes por minuto."
                     : "Extrapolación del radar: una muestra visual cada minuto. Altura = señal de eco, no mm/h. La incertidumbre crece con el horizonte.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let p = projection {
                    HStack {
                        Label("Confianza \(Int(p.confidence * 100)) %", systemImage: "scope")
                        Spacer()
                        Text("Orientativa hasta +\(p.reliableUntil) min")
                    }
                    .font(.caption)
                    .foregroundStyle(.cyan)
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct LongRainForecast: View {
    let weather: RainSnapshot?
    @State private var hours = 72
    private var shown: [HourlyRain] {
        guard let wx = weather else { return [] }
        return Array(wx.hours.filter { $0.time >= Date().addingTimeInterval(-3600) }.prefix(hours))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Previsión de varios días", systemImage: "calendar")
                .font(.headline)
            Picker("Horizonte", selection: $hours) {
                Text("24 h").tag(24)
                Text("72 h").tag(72)
                Text("7 días").tag(168)
            }
            .pickerStyle(.segmented)

            if !shown.isEmpty {
                Chart(shown) { item in
                    BarMark(x: .value("Hora", item.time),
                            y: .value("mm/h", item.millimeters))
                        .foregroundStyle(item.probability >= 70 ? Color.indigo :
                                         item.probability >= 40 ? Color.blue : Color.cyan.opacity(0.6))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: hours == 168 ? .day : .hour,
                                              count: hours == 24 ? 4 : hours == 72 ? 12 : 1)) { _ in
                        AxisValueLabel(format: hours == 168 ? .dateTime.weekday(.abbreviated) :
                                                       .dateTime.day().hour())
                        AxisTick()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 180)
                Text("Precipitación por hora en mm · Azul más intenso = mayor probabilidad. El gráfico usa predicción meteorológica, no radar futuro.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let days = weather?.days, !days.isEmpty {
                ForEach(days) { day in
                    HStack(spacing: 10) {
                        Text(day.date.formatted(.dateTime.weekday(.wide).day()))
                            .font(.subheadline.weight(.medium))
                            .frame(width: 116, alignment: .leading)
                        Image(systemName: day.probability >= 50 ? "cloud.rain.fill" : "cloud.sun.fill")
                            .foregroundStyle(day.probability >= 50 ? .cyan : .yellow)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f mm", day.totalMM))
                                .font(.subheadline.bold())
                            Text("\(day.probability)% · \(temperatures(day))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 7)
                    Divider().overlay(.white.opacity(0.04))
                }
                Text("Siete días · Fuente Open-Meteo. Las probabilidades y acumulaciones son estimaciones de modelos; su fiabilidad disminuye con el plazo.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Sin previsión de varios días. Desliza hacia abajo para actualizar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private func temperatures(_ day: DailyRain) -> String {
        guard let min = day.minTemperature, let max = day.maxTemperature else { return "–" }
        return "\(Int(min.rounded()))°/\(Int(max.rounded()))°"
    }
}
