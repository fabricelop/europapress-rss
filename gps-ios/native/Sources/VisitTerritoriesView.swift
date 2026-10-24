import SwiftUI
import MapKit
import Combine

/// Primera versión de "Territorios" dentro de Descubrir.
/// Solo utiliza transiciones de visita registradas en Mi Mapa del Tiempo.
struct VisitTerritoriesView: View {
    @ObservedObject var model: TimeModel
    @State private var period: VisitTerritoryPeriod = .all
    @State private var result: VisitTerritorySnapshot?
    @State private var loading = false
    @State private var selected: VisitTerritoryRegion?
    @State private var camera: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var request = UUID()
    @State private var followUser = false
    @State private var showHelp = false

    private let palette: [Color] = [
        .blue, .green, .orange, .purple,
        .pink, .cyan, .mint, .indigo
    ]

    private func color(_ region: VisitTerritoryRegion?) -> Color {
        guard let region else { return Color.gray }
        return palette[region.colorIndex % palette.count]
    }

    private func shade(_ tile: VisitTerritoryCell,
                       snapshot: VisitTerritorySnapshot) -> Color {
        switch tile.classification {
        case .neutral: return .gray.opacity(0.16)
        case .disputed: return .yellow.opacity(0.32)
        case .nucleus: return color(snapshot.region(tile.territoryID)).opacity(0.67)
        case .periphery: return color(snapshot.region(tile.territoryID)).opacity(0.32)
        }
    }

    private func border(_ tile: VisitTerritoryCell,
                        snapshot: VisitTerritorySnapshot) -> Color {
        switch tile.classification {
        case .neutral: return .gray.opacity(0.35)
        case .disputed: return .yellow
        case .nucleus, .periphery:
            return tile.frontier ? color(snapshot.region(tile.territoryID))
                                 : color(snapshot.region(tile.territoryID)).opacity(0.36)
        }
    }

    private func centerOnCurrent(snapshot: VisitTerritorySnapshot?) {
        let cell = model.activeCell ?? snapshot?.territories.first?.peak
        guard let cell else { return }
        camera = .region(MKCoordinateRegion(center: Grid.center(cell),
            span: MKCoordinateSpan(latitudeDelta: 0.007, longitudeDelta: 0.009)))
    }

    private func refresh(recenter: Bool = false) {
        let generation = UUID()
        request = generation
        let intervals = model.data.intervals
        let selectedPeriod = period
        let now = Date()
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let next = VisitTerritoryEngine.calculate(intervals,
                period: selectedPeriod, now: now)
            DispatchQueue.main.async {
                guard request == generation else { return }
                result = next
                loading = false
                selected = nil
                if recenter { centerOnCurrent(snapshot: next) }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            periodControls
            if let result {
                territoryMap(result)
                    .frame(maxHeight: .infinity)
                summary(result)
            } else if loading {
                Spacer()
                ProgressView("Agrupando cuadrículas según las visitas…")
                Spacer()
            } else {
                ContentUnavailableView("Sin territorios todavía",
                    systemImage: "square.3.layers.3d",
                    description: Text("Tus regresos a las cuadrículas irán formando territorios."))
            }
        }
        .navigationTitle("Territorios")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // El historial puede corregirse sin cambiar el número de intervalos.
            // Permite reconstruir los territorios manualmente en ese caso.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .accessibilityLabel("Actualizar territorios")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Cómo se forman los territorios")
            }
        }
        .onAppear {
            if result == nil { refresh(recenter: true) }
        }
        .onChange(of: period) { _, _ in refresh() }
        .onChange(of: model.data.intervals.count) { _, _ in refresh() }
        .sheet(item: $selected) { region in
            if let snapshot = result {
                VisitTerritoryDetailView(model: model,
                    region: region, snapshot: snapshot,
                    tint: color(region))
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Cómo funcionan los territorios", isPresented: $showHelp) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text("Se cuenta cada entrada registrada en una cuadrícula, no sus minutos. Dos visitas activan una cuadrícula. Las activas contiguas forman un territorio; una cuadrícula visitada una vez puede ser periferia o estar disputada. El mapa es una simulación matemática independiente de BIOGRID y no modifica tu historial GPS.")
        }
    }

    private var periodControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Territorios por visitas", systemImage: "square.3.layers.3d")
                    .font(.caption.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
            }
            Picker("Período", selection: $period) {
                ForEach(VisitTerritoryPeriod.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Período de visitas")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func territoryMap(_ snapshot: VisitTerritorySnapshot) -> some View {
        let visible: [VisitTerritoryCell]
        if let region = visibleRegion {
            visible = snapshot.renderTiles(
                near: region.center.latitude, longitude: region.center.longitude,
                latitudeDelta: region.span.latitudeDelta,
                longitudeDelta: region.span.longitudeDelta)
        } else {
            visible = snapshot.renderTiles
        }
        let anchors = snapshot.annotationAnchors(for: visible)
        return MapReader { proxy in
            Map(position: $camera) {
                ForEach(visible) { tile in
                    MapPolygon(coordinates: Grid.polygon(tile.cell))
                        .foregroundStyle(shade(tile, snapshot: snapshot))
                        .stroke(border(tile, snapshot: snapshot),
                                lineWidth: tile.frontier ? 1.35 : 0.5)
                }
                ForEach(anchors) { anchor in
                    Annotation("", coordinate: Grid.center(anchor.cell)) {
                        Button {
                            selected = anchor.region
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "circle.hexagongrid.fill")
                                    .foregroundStyle(color(anchor.region))
                                Text(model.label(for: anchor.region.peak))
                                    .lineLimit(1)
                                Text("\(anchor.region.visits)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.regularMaterial,
                                        in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Abrir territorio \(model.label(for: anchor.region.peak))")
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else {
                    return
                }
                let cell = Grid.cell(latitude: coordinate.latitude,
                                     longitude: coordinate.longitude)
                if let tile = snapshot.tile(cell.id),
                   let region = snapshot.region(tile.territoryID) {
                    selected = region
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    followUser = true
                    centerOnCurrent(snapshot: snapshot)
                } label: {
                    Image(systemName: "location.fill")
                        .frame(width: 43, height: 43)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Centrar en mi cuadrícula")
                .padding(10)
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 11) {
                    legend(.blue, "Núcleo", 0.8)
                    legend(.blue, "Periferia", 0.3)
                    legend(.yellow, "Disputada", 0.5)
                    legend(.gray, "Neutral", 0.18)
                }
                .font(.system(size: 9))
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 7)
            }
            .overlay(alignment: .topLeading) {
                if visible.count < snapshot.tiles.count {
                    Text("En esta zona: \(visible.count.formatted()) de \(snapshot.tiles.count.formatted()) cuadrículas")
                        .font(.caption2)
                        .padding(5)
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .padding(7)
                }
            }
        }
    }

    private func legend(_ tint: Color, _ name: String,
                        _ alpha: Double) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(alpha))
                .frame(width: 11, height: 11)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(tint.opacity(0.8), lineWidth: 0.7))
            Text(name).lineLimit(1)
        }
    }

    private func summary(_ snapshot: VisitTerritorySnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("Resumen de territorios", systemImage: "map.fill")
                        .font(.headline)
                    Spacer()
                    Text(snapshot.period.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 9) {
                    stat("Países", value: snapshot.territories.count,
                         symbol: "square.3.layers.3d")
                    stat("Fronteras disputadas", value: snapshot.disputedCount,
                         symbol: "square.dashed")
                    stat("Núcleos", value: snapshot.nucleiCount,
                         symbol: "scope")
                }
                HStack {
                    Text("\(snapshot.totalVisits.formatted()) visitas")
                    Spacer()
                    Text("\(snapshot.occupied.formatted()) cuadrículas visitadas")
                }
                .font(.caption).foregroundStyle(.secondary)
                if snapshot.territories.isEmpty {
                    Text("Todavía no hay cuadrículas con dos visitas en este período. Las visitadas una sola vez permanecen neutrales.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Territorios principales")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Visitas · casillas")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(Array(snapshot.territories.prefix(4))) { region in
                        Button {
                            selected = region
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(color(region))
                                    .frame(width: 13, height: 13)
                                Text(model.label(for: region.peak))
                                    .lineLimit(1)
                                Spacer(minLength: 5)
                                Text("\(region.visits) · \(region.cells)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                            }
                            .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 245)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func stat(_ title: String, value: Int,
                      symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(.teal)
            Text(value.formatted())
                .font(.headline.monospacedDigit())
            Text(title).font(.system(size: 10))
                .lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct VisitTerritoryDetailView: View {
    @ObservedObject var model: TimeModel
    let region: VisitTerritoryRegion
    let snapshot: VisitTerritorySnapshot
    let tint: Color

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.label(for: region.peak))
                                .font(.headline)
                            Text("Núcleo en la cuadrícula \(region.id)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.3.layers.3d")
                            .foregroundStyle(tint)
                    }
                    LabeledContent("Total de visitas",
                                   value: region.visits.formatted())
                    LabeledContent("Cuadrículas del territorio",
                                   value: region.cells.formatted())
                    LabeledContent("Núcleos", value: region.nuclei.formatted())
                    LabeledContent("Periferia", value: region.periphery.formatted())
                    LabeledContent("Cuadrículas de frontera",
                                   value: region.frontiers.formatted())
                    LabeledContent("Visitas al núcleo",
                                   value: region.peakVisits.formatted())
                } header: {
                    Text("Estadísticas · \(snapshot.period.title)")
                }
                Section {
                    NavigationLink {
                        CellHistoryView(model: model, cell: region.peak)
                    } label: {
                        Label("Ver historial de la cuadrícula núcleo",
                              systemImage: "clock.arrow.circlepath")
                    }
                    Text("Los territorios se agrupan por proximidad y cantidad de visitas. Una casilla solo visitada una vez no une dos países.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Detalle del territorio")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
