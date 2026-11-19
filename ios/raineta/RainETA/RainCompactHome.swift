import SwiftUI

// RainETA's simplified mobile front page uses the same RainStore decisions
// as the detailed screens. These cards never create an independent ETA.
enum RainCompactSection: String, CaseIterable, Identifiable {
    case hours, day, days, radar
    var id: String { rawValue }

    static let defaultOrder = "hours,day,days,radar"

    var title: String {
        switch self {
        case .hours: return "Próximas horas"
        case .day: return "24 horas"
        case .days: return "10 días"
        case .radar: return "Radar"
        }
    }

    var icon: String {
        switch self {
        case .hours: return "figure.walk"
        case .day: return "chart.bar.fill"
        case .days: return "calendar"
        case .radar: return "dot.radiowaves.left.and.right"
        }
    }

    static func ordered(_ raw: String) -> [RainCompactSection] {
        var seen = Set<RainCompactSection>()
        let requested = raw.split(separator: ",").compactMap { RainCompactSection(rawValue: String($0)) }
        return (requested + allCases).filter { seen.insert($0).inserted }
    }

    static func visible(order: String, hidden: String) -> [RainCompactSection] {
        let disabled = Set(hidden.split(separator: ",").compactMap { RainCompactSection(rawValue: String($0)) })
        return ordered(order).filter { !disabled.contains($0) }
    }
}

struct RainCompactCustomizeView: View {
    @Binding var order: String
    @Binding var hidden: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(RainCompactSection.ordered(order)) { section in
                        Toggle(isOn: Binding(
                            get: { RainCompactSection.visible(order: order, hidden: hidden).contains(section) },
                            set: { isVisible in
                                var disabled = Set(hidden.split(separator: ",").compactMap {
                                    RainCompactSection(rawValue: String($0))
                                })
                                if isVisible { disabled.remove(section) }
                                else { disabled.insert(section) }
                                hidden = RainCompactSection.allCases
                                    .filter { disabled.contains($0) }
                                    .map(\.rawValue).joined(separator: ",")
                            }
                        )) {
                            Label(section.title, systemImage: section.icon)
                        }
                    }
                    .onMove { offsets, destination in
                        var sections = RainCompactSection.ordered(order)
                        sections.move(fromOffsets: offsets, toOffset: destination)
                        order = sections.map(\.rawValue).joined(separator: ",")
                    }
                } header: {
                    Text("Inicio")
                } footer: {
                    Text("El estado de lluvia se mantiene siempre visible. Pulso, gráficos avanzados y comparación de modelos están disponibles en «Detalles».")
                }
                Section {
                    Button("Restaurar distribución") {
                        order = RainCompactSection.defaultOrder
                        hidden = ""
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Organizar tarjetas")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct RainCompactNowCard: View {
    @ObservedObject var store: RainStore

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label(store.name, systemImage: "location.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
            }

            if let weather = store.snapshot {
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    let now = clock.date
                    let old = now.timeIntervalSince(weather.updatedAt) > 30 * 60
                    let short = store.shortEstimate?.isUsable(at: now) == true ? store.shortEstimate : nil
                    let fallback = RainInsight.transition(currentIsRaining: weather.isRaining,
                                                          samples: weather.samples, now: now)
                    let wet = short?.rainingNow ?? fallback.raining
                    let changed = short?.change ?? fallback.change
                    let radar = short?.radarBased == true
                    let phase = weather.phase(at: wet ? now : (changed ?? now))

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(old ? "Previsión desactualizada" :
                                     radar ? (wet ? "Eco de precipitación" : "Sin eco de precipitación") :
                                     wet ? "Modelo prevé precipitación" : "No se prevé lluvia ahora")
                                    .font(.title3.bold())
                                Text(old ? "Actualiza antes de utilizar la previsión" :
                                     radar ? "Radar reciente · no confirma lluvia en el suelo" :
                                     "Según modelos · sin confirmación por radar")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: old ? "clock.badge.exclamationmark" :
                                  wet ? phase.glyph : "cloud")
                                .font(.system(size: 34))
                                .foregroundStyle(old ? .orange : wet ? .cyan : .mint)
                        }

                        if !old {
                            HStack(alignment: .firstTextBaseline, spacing: 11) {
                                if let changed {
                                    Text(RainInsight.countdown(to: changed, at: now))
                                        .font(.system(size: 35, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(wet ? "Hasta el fin estimado" : "Hasta la próxima lluvia")
                                            .font(.caption.bold())
                                        Text(changed.formatted(date: .omitted, time: .shortened) + " · orientativo")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("Sin cambio con hora fiable")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }

                        HStack(spacing: 7) {
                            Text(short?.confidence ?? "Modelo orientativo")
                            Text("·")
                            Text("Act. " + weather.updatedAt.formatted(date: .omitted, time: .shortened))
                            Spacer(minLength: 0)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Comprobando lluvia y próximo cambio…")
                    .padding(.vertical, 22)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red:0.025,green:0.19,blue:0.28),
                                    Color(red:0.055,green:0.09,blue:0.17)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .overlay(RoundedRectangle(cornerRadius: 22)
                 .stroke(Color.cyan.opacity(0.20)))
    }
}

enum RainCompactData {
    // Returns the longest continuous fully-covered dry forecast interval,
    // not an absolute promise that no precipitation will occur.
    static func bestDryRange(_ bins: [RainOverviewBin]) -> Range<Int>? {
        var longest: Range<Int>?
        var start: Int?
        for index in 0...bins.count {
            let dry = index < bins.count &&
                bins[index].meanRate != nil &&
                bins[index].rainyMinutes == 0 &&
                (index == 0 || bins[index].startMinute - bins[index-1].startMinute == 15)
            if dry {
                if start == nil { start = index }
            } else if let first = start {
                let candidate = first..<index
                if candidate.count >= 2 && (longest == nil || candidate.count > longest!.count) {
                    longest = candidate
                }
                start = nil
            }
        }
        return longest
    }

    static func color(_ bin: RainOverviewBin) -> Color {
        guard bin.meanRate != nil else { return Color.gray.opacity(0.25) }
        if bin.snow && bin.rainyMinutes > 0 { return Color.white.opacity(0.92) }
        if bin.rainyMinutes > 0 { return RainVisual.color(max(0.15,bin.peakRate ?? 0)) }
        return Color.mint.opacity(0.68)
    }

    static func label(_ bin: RainOverviewBin) -> String {
        guard let peak = bin.peakRate, bin.meanRate != nil else { return "Datos insuficientes" }
        if bin.snow && bin.rainyMinutes > 0 { return "Posible nieve" }
        return bin.rainyMinutes > 0 ? RainVisual.intensity(peak) : "Sin lluvia relevante prevista"
    }

    // The short-range provider may have gaps. Preserve one explicit slot for
    // every minute so the graph never joins two known points across missing data.
    // A visual one-minute slot is not a fresh one-minute meteorological reading.
    static func minuteWave(_ minutes: [RadarWeightedMinute],
                           weather: RainSnapshot?, now: Date,
                           horizon: Int = 60) -> [RainWavePoint] {
        guard horizon >= 0 else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: minutes.map { ($0.minute, $0) })
        return (0...horizon).map { minute in
            let sample = lookup[minute]
            return RainWavePoint(
                minute: minute,
                rate: sample?.rate,
                snow: sample.map { $0.rate >= 0.15 && weather?.phase(at: $0.at) == .snow } ?? false,
                date: now.addingTimeInterval(Double(minute * 60))
            )
        }
    }
}

struct RainCompactHoursCard: View {
    @ObservedObject var store: RainStore
    @State private var selection = 0
    @State private var minuteMode = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Lluvia a corto plazo", systemImage: "waveform.path")
                .font(.headline)
            Picker("Horizonte de lluvia", selection: $minuteMode) {
                Text("Minuto a minuto · 60 min").tag(true)
                Text("3 horas").tag(false)
            }
            .pickerStyle(.segmented)
            if minuteMode {
                RainCompactMinuteDetail(store: store)
            } else if let weather = store.snapshot {
                let now = Date()
                let samples = store.minuteForecast(now: now, horizon: 179)
                let bins = RainVisualForecast.overview(samples, weather: weather,
                                                       horizon: 180, binSize: 15)
                let selected = bins[min(max(0, selection), max(0, bins.count - 1))]
                let best = RainCompactData.bestDryRange(bins)

                if let best {
                    let first = now.addingTimeInterval(Double(bins[best.lowerBound].startMinute * 60))
                    let final = now.addingTimeInterval(Double((bins[best.upperBound-1].startMinute + 15) * 60))
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                        Text("Mejor tramo previsto: " +
                             first.formatted(date: .omitted, time: .shortened) + "–" +
                             final.formatted(date: .omitted, time: .shortened))
                            .font(.subheadline.bold())
                            .lineLimit(2)
                    }
                } else {
                    Text(bins.contains(where: { $0.meanRate == nil }) ?
                         "Datos parciales: sin ventana clara para salir" :
                         "No aparece una ventana seca de 30 min")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 3) {
                    ForEach(Array(bins.enumerated()), id: \.offset) { index, bin in
                        Button {
                            selection = index
                        } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(RainCompactData.color(bin))
                                .frame(height: bin.rainyMinutes > 0 ? 39 : 30)
                                .overlay {
                                    if selection == index {
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(Color.white, lineWidth: 1.8)
                                    }
                                }
                                .frame(maxHeight: 44, alignment: .bottom)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("+\(bin.startMinute) minutos: " + RainCompactData.label(bin))
                    }
                }
                .frame(height: 44)

                HStack {
                    Text("Ahora")
                    Spacer()
                    Text("+1 h")
                    Spacer()
                    Text("+2 h")
                    Spacer()
                    Text("+3 h")
                }
                .font(.system(size:10, design:.rounded))
                .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(now.addingTimeInterval(Double(selected.startMinute * 60))
                        .formatted(date:.omitted,time:.shortened))
                        .font(.subheadline.bold().monospacedDigit())
                    Text(RainCompactData.label(selected))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let peak = selected.peakRate, selected.rainyMinutes > 0 {
                        Text(String(format: "%.1f mm/h", peak))
                            .font(.caption.bold().monospacedDigit())
                    }
                }
                Text("Tramos de 15 min · radar reciente cuando está disponible; después, modelos.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Consultando las próximas horas…")
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius:20))
    }
}

// A compact minute-by-minute look at the SAME short-range series used by
// the countdown, Live Activity and detailed Pulse. This does not fetch or
// manufacture higher-resolution measurements.
struct RainCompactMinuteDetail: View {
    @ObservedObject var store: RainStore
    @State private var selectedMinute: Int?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { clock in
            if let weather = store.snapshot {
                let now = clock.date
                let minutes = store.minuteForecast(now: now, horizon: 60)
                let points = RainCompactData.minuteWave(minutes, weather: weather, now: now)
                if points.contains(where: { $0.rate != nil }) {
                    let index = min(max(selectedMinute ?? 0, 0), 60)
                    let selected = points[index]
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(index == 0 ? "Ahora" : "En +\(index) min")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(selected.rate.map { RainVisual.intensity($0) } ??
                                     "Sin datos para este minuto")
                                    .font(.subheadline.bold())
                            }
                            Spacer(minLength: 0)
                            if let rate = selected.rate {
                                Text(String(format: "%.1f mm/h", rate))
                                    .font(.subheadline.bold().monospacedDigit())
                                    .foregroundStyle(.cyan)
                            }
                        }
                        RainWavePlot(points: points, height: 118,
                                     selectedIndex: selectedMinute,
                                     onSelect: { selectedMinute = $0 })
                        HStack {
                            Text("Ahora")
                            Spacer()
                            Text("+15")
                            Spacer()
                            Text("+30")
                            Spacer()
                            Text("+45")
                            Spacer()
                            Text("+60 min")
                        }
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                        RainWaveRibbon(points: points)
                        Text("Azul: lluvia · Violeta: posible · Verde: seco · Gris: sin datos")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("1 punto por minuto, estimado. Radar local cuando es válido; el resto procede de modelos e interpolación. No es una medición nueva cada minuto.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Sin datos suficientes para los próximos 60 minutos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Consultando la próxima hora…")
            }
        }
    }
}

struct RainCompactDayCard: View {
    let weather: RainSnapshot?
    @State private var selection = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Próximas 24 horas", systemImage: "chart.bar.fill")
                .font(.headline)
            if let weather {
                let hours = RainVisualForecast.daily24(weather, now: Date())
                if hours.isEmpty {
                    Text("Previsión horaria no disponible.")
                        .foregroundStyle(.secondary)
                } else {
                    let total = hours.reduce(0.0) { $0 + $1.millimeters }
                    let peak = hours.max(by: { $0.millimeters < $1.millimeters })
                    let chance = hours.map(\.probability).max() ?? 0
                    let selected = hours[min(max(selection, 0), hours.count - 1)]
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%.1f mm", total))
                            .font(.title2.bold().monospacedDigit())
                        Text(hours.count < 24 ? "datos parciales" : "total previsto")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(chance)% prob. máx.")
                            .font(.subheadline.bold())
                            .foregroundStyle(.cyan)
                    }
                    if let peak, peak.millimeters >= 0.1 {
                        Text("Pico previsto " + peak.end.addingTimeInterval(-3600)
                            .formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            HStack(alignment: .bottom, spacing: 3) {
                                ForEach(hours) { hour in
                                    Button { selection = hour.index } label: {
                                        let maximum = max(0.2, hours.map(\.millimeters).max() ?? 0)
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(hour.snowCM >= 0.1 ? Color.white.opacity(0.90) :
                                                  hour.millimeters >= 0.1 ? Color.cyan :
                                                  Color.gray.opacity(0.18))
                                            .frame(height: hour.millimeters < 0.1 ? 4 :
                                                   max(7, CGFloat(hour.millimeters / maximum) * 80))
                                            .overlay {
                                                if selection == hour.index {
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .stroke(Color.white.opacity(0.96), lineWidth: 1.5)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                                           alignment: .bottom)
                                    .accessibilityLabel(hour.end.addingTimeInterval(-3600)
                                        .formatted(date:.omitted,time:.shortened) + " · " +
                                        String(format:"%.1f mm, %d%%",hour.millimeters,hour.probability))
                                }
                            }
                            Canvas { context, size in
                                guard hours.count > 1 else { return }
                                var path = Path()
                                for (index,hour) in hours.enumerated() {
                                    let x = (CGFloat(index) + 0.5) * size.width / CGFloat(hours.count)
                                    let y = (size.height - 9) - CGFloat(hour.probability) * (size.height - 19) / 100
                                    if index == 0 { path.move(to: CGPoint(x:x,y:y)) }
                                    else { path.addLine(to: CGPoint(x:x,y:y)) }
                                }
                                context.stroke(path, with: .color(.orange.opacity(0.9)),
                                               style: StrokeStyle(lineWidth:1.8, dash:[4,3]))
                            }
                            .allowsHitTesting(false)
                        }
                        .frame(height: geo.size.height)
                    }
                    .frame(height: 92)

                    HStack {
                        Text("Ahora")
                        Spacer()
                        Text("+12 h")
                        Spacer()
                        Text("+24 h")
                    }
                    .font(.system(size:10,design:.rounded))
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text(selected.end.addingTimeInterval(-3600)
                            .formatted(date:.omitted,time:.shortened))
                            .font(.caption.bold().monospacedDigit())
                        Text(String(format: "%.1f mm · %d%%", selected.millimeters, selected.probability))
                            .font(.caption)
                        Spacer()
                        Text("Barras: mm · línea: %")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Consultando lluvia de 24 h…")
            }
        }
        .padding(15)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(Color.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
    }
}

struct RainDayMiniHour: Identifiable {
    let start: Date
    let amount: Double?
    let probability: Int?
    var id: Date { start }
}

enum RainTenDayData {
    static func hourly(day: DailyRain, hours: [HourlyRain],
                       calendar: Calendar = .current) -> [RainDayMiniHour] {
        guard let interval = calendar.dateInterval(of: .day, for: day.date) else { return [] }
        return stride(from: interval.start.timeIntervalSince1970,
                      to: interval.end.timeIntervalSince1970, by: 3600).map { stamp in
            let start = Date(timeIntervalSince1970: stamp)
            let end = start.addingTimeInterval(3600)
            let match = hours.first { abs($0.time.timeIntervalSince(end)) < 60 }
            return RainDayMiniHour(start: start, amount: match?.millimeters,
                                   probability: match?.probability)
        }
    }

    static func wettest(_ days: [DailyRain]) -> DailyRain? {
        days.filter { $0.totalMM >= 0.1 }.max { $0.totalMM < $1.totalMM }
    }

    static func color(_ hour: RainDayMiniHour) -> Color {
        guard let amount = hour.amount else { return Color.gray.opacity(0.12) }
        if amount >= 0.1 { return RainVisual.color(max(0.15,amount)) }
        return (hour.probability ?? 0) >= 30 ?
            Color.purple.opacity(0.55) : Color.gray.opacity(0.25)
    }
}

struct RainCompactTenDaysCard: View {
    let weather: RainSnapshot?
    @State private var selectedDay: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let weather {
                let days = Array(weather.days.prefix(10))
                HStack {
                    Label("Previsión · \(days.count) días", systemImage: "calendar")
                        .font(.headline)
                    Spacer()
                    if let wettest = RainTenDayData.wettest(days) {
                        Text(String(format: "Máx. %.1f mm", wettest.totalMM))
                            .font(.caption.bold())
                            .foregroundStyle(.cyan)
                    }
                }
                if days.isEmpty {
                    Text("Previsión diaria no disponible.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(days) { day in
                            Button {
                                selectedDay = day.date
                            } label: {
                                HStack(spacing: 9) {
                                    Text(RainSpanishDates.day(day.date))
                                        .font(.system(size: 12, weight:.bold))
                                        .frame(width: 65, alignment:.leading)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.72)
                                    let miniHours = RainTenDayData.hourly(day:day, hours:weather.hours)
                                    HStack(alignment:.bottom,spacing:2) {
                                        ForEach(miniHours) { hour in
                                            Capsule()
                                                .fill(RainTenDayData.color(hour))
                                                .frame(maxWidth:.infinity)
                                                .frame(height:hour.amount.map { $0 >= 0.1 ? 18.0 : 6.0 } ?? 6)
                                        }
                                    }
                                    .frame(height:22,alignment:.bottom)
                                    if miniHours.isEmpty {
                                        Text("—").font(.caption)
                                    }
                                    Text(String(format: "%.1f mm",day.totalMM))
                                        .font(.system(size: 12, weight:.bold,design:.rounded))
                                        .monospacedDigit()
                                        .frame(width:57,alignment:.trailing)
                                    Text("\(day.probability)%")
                                        .font(.system(size: 13, weight:.bold,design:.rounded))
                                        .foregroundStyle(.cyan)
                                        .monospacedDigit()
                                        .frame(width:42,alignment:.trailing)
                                }
                                .frame(minHeight:40)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if day.id != days.last?.id {
                                Divider().overlay(Color.white.opacity(0.04))
                            }
                        }
                    }
                    HStack(spacing: 7) {
                        Text("Azul: lluvia")
                        Text("·")
                        Text("Violeta: posible")
                        Text("·")
                        Text("mm / prob. máx.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Text("Toca un día para ver las horas. Celdas grises claras: sin detalle disponible.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Previsión diaria",systemImage:"calendar")
                    .font(.headline)
                ProgressView("Consultando próximos días…")
            }
        }
        .padding(15)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(Color.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
        .sheet(item: Binding<RainWeekSelection?>(
            get: { selectedDay.map { RainWeekSelection(date:$0) } },
            set: { selectedDay = $0?.date }
        )) { selection in
            if let weather, let day = weather.days.first(where: {
                Calendar.current.isDate($0.date, inSameDayAs:selection.date)
            }) {
                RainDayDetail(weather:weather,day:day)
            }
        }
    }
}

struct RainCompactRadarCard: View {
    @ObservedObject var store: RainStore
    let open: () -> Void

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Label("Radar de lluvia",systemImage:"dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Button("Ampliar",action:open)
                    .font(.caption.bold())
            }
            RadarMap(center:store.coordinate, host:store.radar.host,
                     framePath:store.radar.latest?.path, projection:nil,
                     modelField:nil, futureMinutes:0, nowcastPath:nil,
                     recenterRevision:0, forecastStatus:{_ in},
                     onForecastReady:{_,_ in})
                .frame(height:192)
                .clipShape(RoundedRectangle(cornerRadius:14))
                .allowsHitTesting(false)
                .accessibilityLabel("Vista previa del radar observado. Abre el mapa para interactuar.")
            HStack(spacing:5) {
                Text(store.radar.latest.map {
                    "Observado " + $0.date.formatted(date:.omitted,time:.shortened)
                } ?? "Radar no disponible")
                Spacer()
                Text(store.radar.source)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button(action:open) {
                Label("Ver radar histórico y proyección",systemImage:"arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(15)
        .background(Color.white.opacity(0.065),in:RoundedRectangle(cornerRadius:20))
    }
}
