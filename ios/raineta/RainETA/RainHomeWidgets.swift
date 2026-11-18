import SwiftUI

// Personalizable in-app cards. These are NOT WidgetKit Home Screen widgets.
// Existing forecast calculations remain in RainStore and their original views.
enum RainHomeWidget: String, CaseIterable, Identifiable {
    case beforeLeaving, dryWindows, pulse, threeHours, radar, day, week, models

    var id: String { rawValue }

    static let defaultOrder = "beforeLeaving,dryWindows,pulse,threeHours,radar,day,week,models"

    var title: String {
        switch self {
        case .beforeLeaving: return "Antes de salir"
        case .dryWindows: return "Ventanas sin lluvia"
        case .pulse: return "Pulso · 2 horas"
        case .threeHours: return "Próximas 3 horas"
        case .radar: return "Radar y previsión"
        case .day: return "Precipitación · 24 horas"
        case .week: return "Previsión · 7 días"
        case .models: return "Comparación de modelos"
        }
    }

    var symbol: String {
        switch self {
        case .beforeLeaving: return "umbrella"
        case .dryWindows: return "cloud.sun"
        case .pulse: return "waveform.path"
        case .threeHours: return "chart.xyaxis.line"
        case .radar: return "dot.radiowaves.left.and.right"
        case .day: return "clock"
        case .week: return "calendar"
        case .models: return "square.stack.3d.up"
        }
    }

    var subtitle: String {
        switch self {
        case .beforeLeaving: return "Cuatro tramos de 15 minutos, con su procedencia"
        case .dryWindows: return "Periodos con poca lluvia prevista, sin promesas de sequedad"
        case .pulse: return "Evolución detallada con información de radar y modelos"
        case .threeHours: return "Precipitación a intervalos de quince minutos"
        case .radar: return "Observaciones y proyección, cada una identificada"
        case .day: return "Acumulación, nieve y probabilidad por hora"
        case .week: return "Días con precipitación prevista"
        case .models: return "Acuerdos y discrepancias de las fuentes"
        }
    }

    static func ordered(from value: String) -> [RainHomeWidget] {
        var seen = Set<RainHomeWidget>()
        let saved = value.split(separator: ",").compactMap { RainHomeWidget(rawValue: String($0)) }
        return (saved + allCases).filter { seen.insert($0).inserted }
    }

    static func hidden(from value: String) -> Set<RainHomeWidget> {
        Set(value.split(separator: ",").compactMap { RainHomeWidget(rawValue: String($0)) })
    }

    static func visible(order: String, hidden: String) -> [RainHomeWidget] {
        let excluded = self.hidden(from: hidden)
        return ordered(from: order).filter { !excluded.contains($0) }
    }
}

struct RainHomeCustomizeView: View {
    @Binding var order: String
    @Binding var hidden: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(RainHomeWidget.ordered(from: order)) { widget in
                        Toggle(isOn: Binding(
                            get: { !RainHomeWidget.hidden(from: hidden).contains(widget) },
                            set: { enabled in
                                var selected = RainHomeWidget.hidden(from: hidden)
                                if enabled { selected.remove(widget) }
                                else { selected.insert(widget) }
                                // Stable persistence order; never discard hidden positions.
                                hidden = RainHomeWidget.allCases
                                    .filter { selected.contains($0) }
                                    .map(\.rawValue).joined(separator: ",")
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(widget.title, systemImage: widget.symbol)
                                    .font(.subheadline.bold())
                                Text(widget.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.cyan)
                    }
                    .onMove { indices, target in
                        var items = RainHomeWidget.ordered(from: order)
                        items.move(fromOffsets: indices, toOffset: target)
                        order = items.map(\.rawValue).joined(separator: ",")
                    }
                } header: {
                    Text("Tarjetas de lluvia")
                } footer: {
                    Text("Arrastra para cambiar el orden y desactiva lo que no quieras ver. El estado actual y la cuenta atrás permanecen siempre en primer lugar. Las preferencias quedan guardadas en este iPhone.")
                }

                Section {
                    Button("Restablecer distribución") {
                        order = RainHomeWidget.defaultOrder
                        hidden = ""
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Organizar RainETA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

enum RainBeforeLeavingAdvice {
    static func headline(_ bins: [RainOverviewBin]) -> String {
        guard bins.count == 4, bins.allSatisfy({ $0.meanRate != nil }) else {
            return "Datos insuficientes para aconsejar una salida"
        }
        if bins.prefix(2).contains(where: { $0.snow && $0.rainyMinutes > 0 }) {
            return "Posible nieve en los próximos 30 minutos"
        }
        if bins.prefix(2).contains(where: { $0.rainyMinutes > 0 }) {
            return "Precipitación prevista en los próximos 30 minutos"
        }
        if bins.suffix(2).contains(where: { $0.rainyMinutes > 0 }) {
            return "Primera media hora sin lluvia relevante prevista"
        }
        return "No se prevé precipitación relevante en la próxima hora"
    }

    static func description(_ bin: RainOverviewBin) -> String {
        guard let peak = bin.peakRate, bin.meanRate != nil else { return "Sin datos" }
        if bin.rainyMinutes == 0 { return "Sin lluvia" }
        if bin.snow { return "Nieve posible" }
        return RainVisual.intensity(peak)
    }
}

struct RainBeforeLeavingCard: View {
    @ObservedObject var store: RainStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Antes de salir", systemImage: "umbrella")
                .font(.headline)
            if let weather = store.snapshot {
                let now = Date()
                let series = store.minuteForecast(now: now, horizon: 59)
                let bins = RainVisualForecast.overview(
                    series, weather: weather, horizon: 60, binSize: 15
                )
                Text(RainBeforeLeavingAdvice.headline(bins))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 6) {
                    ForEach(bins) { bin in
                        VStack(alignment: .leading, spacing: 7) {
                            Text("+\(bin.startMinute)–\(bin.startMinute + 15)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(bin.meanRate == nil ? Color.gray.opacity(0.15) :
                                      bin.snow ? Color.white.opacity(0.85) :
                                      RainVisual.color(bin.peakRate ?? 0))
                                .frame(height: 9)
                            Text(RainBeforeLeavingAdvice.description(bin))
                                .font(.system(size: 10, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                Text(bins.contains(where: { $0.meanRate == nil }) ?
                     "Cobertura parcial: un tramo sin datos no equivale a tiempo seco." :
                     bins.contains(where: { $0.radarMinutes > 0 }) ?
                     "Previsión local con radar reciente y modelos. No es una observación futura." :
                     "Previsión de modelos; sin comprobación de radar reciente.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Consultando la previsión de lluvia…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cyan.opacity(0.075),
                    in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
                 .stroke(Color.cyan.opacity(0.16), lineWidth: 1))
    }
}

struct RainDryWindow: Identifiable {
    let start: Date
    let end: Date
    var id: Date { start }
}

enum RainDryWindowForecast {
    // An hour is dry-ish only when both expected amount and probability are
    // low. Missing model hours and discontinuities MUST NOT be bridged.
    static func windows(hours: [HourlyRain], from now: Date,
                        horizon: TimeInterval = 12 * 3600) -> [RainDryWindow] {
        let finish = now.addingTimeInterval(horizon)
        let ordered = hours.filter { $0.time > now && $0.time.addingTimeInterval(-3600) < finish }
            .sorted { $0.time < $1.time }
        var result: [RainDryWindow] = []
        var start: Date?
        var end: Date?
        func close() {
            if let begin = start, let last = end,
               last.timeIntervalSince(begin) >= 30 * 60 {
                result.append(RainDryWindow(start: begin, end: last))
            }
            start = nil
            end = nil
        }
        for hour in ordered {
            let beginning = max(now, hour.time.addingTimeInterval(-3600))
            let ending = min(finish, hour.time)
            let probablyDry = hour.millimeters >= 0 &&
                hour.millimeters < 0.1 && hour.probability >= 0 &&
                hour.probability < 35
            if !probablyDry || ending <= beginning {
                close()
                continue
            }
            if let previous = end, abs(beginning.timeIntervalSince(previous)) > 60 {
                close()
            }
            if start == nil { start = beginning }
            end = ending
        }
        close()
        return result
    }
}

struct RainDryWindowsCard: View {
    let weather: RainSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Ventanas con poca lluvia · 12 h", systemImage: "cloud.sun")
                .font(.headline)
            if let weather {
                let windows = RainDryWindowForecast.windows(hours: weather.hours, from: Date())
                if windows.isEmpty {
                    Text("Sin una ventana probablemente seca que podamos destacar.")
                        .font(.subheadline)
                } else {
                    ForEach(Array(windows.prefix(3))) { window in
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.mint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(window.start.formatted(date: .omitted, time: .shortened))–\(window.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.subheadline.bold())
                                Text("Poca precipitación prevista")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                Text("Solo modelos horarios. La baja probabilidad no garantiza que no llueva, y los intervalos sin datos no se consideran secos.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sin datos para calcular las ventanas.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.065),
                    in: RoundedRectangle(cornerRadius: 20))
    }
}
