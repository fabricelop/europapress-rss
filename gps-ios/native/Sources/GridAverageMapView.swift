import SwiftUI
import MapKit
import Combine

/// Purely analytical presentation: never writes intervals, GPS locations,
/// visit counters, territorial caches or BIOGRID simulation state.
private enum GridAverageMode: String, CaseIterable, Identifiable {
    case average, deviation, consistency
    var id: String { rawValue }
    var name: String {
        switch self {
        case .average: return "Tiempo medio"
        case .deviation: return "Vs. media"
        case .consistency: return "Constancia"
        }
    }
    var title: String {
        switch self {
        case .average: return "Tiempo medio por visita"
        case .deviation: return "Desviación de la media"
        case .consistency: return "Consistencia"
        }
    }
}

struct GridAverageMapView: View {
    @ObservedObject var model: TimeModel
    @Environment(\.scenePhase) private var phase
    @State private var mode: GridAverageMode = .average
    @State private var period: TimePeriod = .all
    @State private var snapshot: GridAverageSnapshot?
    @State private var camera: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selectedID: String?
    @State private var requestID = UUID()
    @State private var loading = false
    @State private var helpOpen = false

    private func refresh(recenter: Bool = false) {
        let id = UUID()
        requestID = id
        let raw = model.data.intervals
        let selectedPeriod = period
        let now = Date()
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let calculated = GridAverageEngine.calculate(raw, period: selectedPeriod, now: now)
            DispatchQueue.main.async {
                guard requestID == id else { return }
                snapshot = calculated
                selectedID = nil
                loading = false
                if recenter { centerMap(on: calculated) }
            }
        }
    }

    private func centerMap(on snapshot: GridAverageSnapshot) {
        guard let cell = model.activeCell ?? snapshot.cells.max(by: {
            $0.visits < $1.visits
        })?.cell else { return }
        camera = .region(MKCoordinateRegion(center: Grid.center(cell),
            span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.018)))
    }

    private func color(_ stat: GridAverageStat, _ snapshot: GridAverageSnapshot) -> Color {
        switch mode {
        case .average:
            // Logarithmic scale: one hour and one week can share one legend.
            let t = min(1, max(0, log1p(stat.average) / log1p(3600)))
            return Color(hue: 0.62 * (1 - t), saturation: 0.84,
                         brightness: 0.9).opacity(0.63)
        case .deviation:
            guard snapshot.globalAverage > 0 else { return .gray.opacity(0.25) }
            let relative = stat.average / snapshot.globalAverage
            if relative < 0.95 {
                let strength = min(1, log(max(0.0001, 1 / relative)) / log(4))
                return Color.blue.opacity(0.2 + 0.63 * strength)
            } else if relative > 1.05 {
                let strength = min(1, log(relative) / log(4))
                return Color.red.opacity(0.2 + 0.63 * strength)
            }
            return Color.gray.opacity(0.25)
        case .consistency:
            guard let cv = stat.variation else { return .gray.opacity(0.16) }
            return Color.blue.opacity(0.2 + 0.65 * (1 - min(1, cv)))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                Picker("Análisis", selection: $mode) {
                    ForEach(GridAverageMode.allCases) { option in
                        Text(option.name).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Período", selection: $period) {
                    ForEach(TimePeriod.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if let snapshot, !snapshot.cells.isEmpty {
                analyticalMap(snapshot)
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: 280)
                summary(snapshot)
            } else if loading {
                Spacer()
                ProgressView("Calculando medias por cuadrícula…")
                Spacer()
            } else {
                Spacer()
                ContentUnavailableView("Sin visitas registradas",
                    systemImage: "chart.bar.xaxis",
                    description: Text("El análisis aparecerá al disponer de tiempo GPS confirmado."))
                Spacer()
            }
        }
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
                    .accessibilityLabel("Recalcular medias")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { helpOpen = true } label: { Image(systemName: "info.circle") }
            }
        }
        .onAppear { if snapshot == nil { refresh(recenter: true) } }
        .onChange(of: period) { _, _ in refresh() }
        .onChange(of: model.data.intervals.count) { _, _ in refresh() }
        .onChange(of: phase) { _, current in
            if current == .active && snapshot != nil { refresh() }
        }
        .alert("Cómo se calcula", isPresented: $helpOpen) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text("Media = tiempo confirmado en una cuadrícula ÷ número de entradas registradas. Tu media global es la suma de tiempos dividida entre todas las visitas. La desviación compara ambas medias. Consistencia analiza cuánto varía la duración de cada visita; requiere al menos tres. Los cálculos se hacen en el iPhone, sin IA, sin modificar el historial ni BIOGRID.")
        }
    }

    private func analyticalMap(_ snapshot: GridAverageSnapshot) -> some View {
        let visible = snapshot.visible(near: visibleRegion)
        return MapReader { proxy in
            Map(position: $camera) {
                ForEach(visible) { stat in
                    MapPolygon(coordinates: Grid.polygon(stat.cell))
                        .foregroundStyle(color(stat, snapshot))
                        .stroke(Color.white.opacity(0.45), lineWidth: 0.35)
                }
                if let selectedID, let selected = snapshot.byID[selectedID] {
                    MapPolygon(coordinates: Grid.polygon(selected.cell))
                        .foregroundStyle(Color.clear)
                        .stroke(Color.indigo, lineWidth: 2.8)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                let cell = Grid.cell(latitude: coordinate.latitude,
                                     longitude: coordinate.longitude)
                selectedID = snapshot.byID[cell.id] == nil ? nil : cell.id
            }
            .overlay(alignment: .top) {
                if let selectedID, let selected = snapshot.byID[selectedID] {
                    selectionCard(selected, snapshot: snapshot)
                        .padding(.horizontal, 22).padding(.top, 12)
                        .allowsHitTesting(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { centerMap(on: snapshot) } label: {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.indigo)
                        .frame(width: 43, height: 43)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Centrar el mapa")
                .padding(10)
                .padding(.top, selectedID == nil ? 0 : 125)
            }
            .overlay(alignment: .bottom) {
                legend
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    private func selectionCard(_ stat: GridAverageStat,
                               snapshot: GridAverageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.label(for: stat.cell))
                    .font(.subheadline.bold()).lineLimit(1)
                Spacer(minLength: 4)
                Button { selectedID = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cerrar detalle")
            }
            HStack {
                Text("Visitas: \(stat.visits)")
                Spacer()
                Text("Total: \(DurationFormat.full(stat.seconds))")
            }
            .font(.caption)
            HStack {
                Text("Media por visita")
                Spacer()
                Text(DurationFormat.full(stat.average)).bold()
            }
            .font(.subheadline)
            if mode == .deviation {
                HStack {
                    Text("Tu media: \(DurationFormat.full(snapshot.globalAverage))")
                    Spacer()
                    let difference = stat.average - snapshot.globalAverage
                    Text("\(difference >= 0 ? "+" : "−")\(DurationFormat.full(abs(difference)))")
                        .fontWeight(.semibold)
                        .foregroundStyle(difference >= 0 ? Color.red : Color.blue)
                }
                .font(.caption)
            }
            if mode == .consistency {
                HStack {
                    Text("Consistencia")
                    Spacer()
                    if let variation = stat.variation {
                        Text(variation <= 0.25 ? "Alta" :
                             variation >= 0.75 ? "Baja" : "Media")
                            .fontWeight(.semibold)
                        Text("CV \(Int((variation * 100).rounded())) %")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Necesita 3 visitas")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 5)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(legendColor(Double(index) / 11.0))
                        .frame(height: 9)
                }
            }
            HStack {
                Text(mode == .average ? "Estancias cortas" :
                     mode == .deviation ? "Menor que tu media" :
                     "Baja / sin datos")
                Spacer()
                Text(mode == .average ? "Estancias largas" :
                     mode == .deviation ? "Mayor que tu media" : "Alta")
            }
            .font(.system(size: 10))
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    }

    private func legendColor(_ t: Double) -> Color {
        switch mode {
        case .average:
            return Color(hue: 0.62 * (1 - t), saturation: 0.84, brightness: 0.9)
        case .deviation:
            if t < 0.5 { return Color.blue.opacity(0.2 + (0.5-t) * 1.6) }
            return Color.red.opacity(0.2 + (t-0.5) * 1.6)
        case .consistency:
            return Color.blue.opacity(0.16 + t * 0.68)
        }
    }

    private func summary(_ snapshot: GridAverageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(mode == .average ? "Resumen de tu mapa" :
                      mode == .deviation ? "Comparación con tu media" :
                      "Regularidad de las visitas",
                      systemImage: "chart.bar.xaxis")
                    .font(.subheadline.bold())
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
            }
            HStack(alignment: .top, spacing: 7) {
                switch mode {
                case .average:
                    metric("Media global",
                           value: DurationFormat.full(snapshot.globalAverage),
                           note: "\(snapshot.totalVisits) visitas")
                    metric("Por encima",
                           value: "\(snapshot.aboveAverage)",
                           note: "cuadrículas")
                    metric("Mayor media",
                           value: DurationFormat.full(snapshot.longestRepeatedAverage),
                           note: "con 2+ visitas")
                case .deviation:
                    metric("Por encima",
                           value: "\(snapshot.aboveAverage)",
                           note: "cuadrículas")
                    metric("Por debajo",
                           value: "\(snapshot.belowAverage)",
                           note: "cuadrículas")
                    metric("Máx. diferencia",
                           value: DurationFormat.full(snapshot.greatestDifference),
                           note: "absoluta")
                case .consistency:
                    metric("Constantes",
                           value: "\(snapshot.stable)",
                           note: "CV ≤ 25 %")
                    metric("Variables",
                           value: "\(snapshot.variable)",
                           note: "CV ≥ 75 %")
                    metric("Evaluadas",
                           value: "\(snapshot.evaluated)",
                           note: "con 3+ visitas")
                }
            }
            if mode == .consistency {
                Text("Consistencia = poca variación entre las duraciones reales de tus visitas. Las cuadrículas con menos de 3 visitas aparecen neutras.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Cada cuadrícula se calcula por separado. Solo se utiliza el tiempo confirmado de las visitas registradas.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.systemGroupedBackground))
    }

    private func metric(_ label: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .padding(9)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
