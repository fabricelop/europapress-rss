import SwiftUI
import MapKit
import CoreLocation
import Combine

/// Plays a recorded journey or stay. It never writes to the stored totals.
struct GPSReplayShell: View {
    let episode: GPSHistoryEpisode
    let intervals: [AssignedInterval]
    @State private var elapsed: Double = 0
    @State private var playing = false
    @State private var speed: Double = 60
    @State private var showRoute = true
    @State private var camera: MapCameraPosition = .automatic
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var playbackDate: Date { episode.start.addingTimeInterval(elapsed) }

    private var playbackPosition: CLLocationCoordinate2D? {
        guard let point = GPSPlaybackPosition.at(playbackDate, in: episode.points).coordinates else {
            return nil
        }
        return .init(latitude: point.latitude, longitude: point.longitude)
    }

    private var cell: Cell? {
        guard let playbackPosition else { return nil }
        return Grid.cell(latitude: playbackPosition.latitude, longitude: playbackPosition.longitude)
    }

    private var accumulated: TimeInterval {
        guard let cell else { return 0 }
        return intervals.reduce(0) { sum, segment in
            guard segment.cell == cell && segment.start < playbackDate else { return sum }
            return sum + max(0, min(segment.end, playbackDate).timeIntervalSince(segment.start))
        }
    }

    private var routeSegments: [[CLLocationCoordinate2D]] {
        GPSRouteSegments.split(episode.points).map { group in
            group.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    private func initialRegion() -> MKCoordinateRegion {
        let latitudes = episode.points.map(\.latitude)
        let longitudes = episode.points.map(\.longitude)
        let lowLat = latitudes.min() ?? 40.4168
        let highLat = latitudes.max() ?? lowLat
        let lowLon = longitudes.min() ?? -3.7038
        let highLon = longitudes.max() ?? lowLon
        return MKCoordinateRegion(
            center: .init(latitude: (lowLat + highLat) / 2, longitude: (lowLon + highLon) / 2),
            span: .init(latitudeDelta: max(0.003, (highLat - lowLat) * 1.4),
                        longitudeDelta: max(0.003, (highLon - lowLon) * 1.4))
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            Map(position: $camera) {
                if showRoute {
                    ForEach(routeSegments.indices, id: \.self) { index in
                        MapPolyline(coordinates: routeSegments[index])
                            .stroke(.blue, lineWidth: 3)
                    }
                }
                if let cell {
                    MapPolygon(coordinates: Grid.polygon(cell))
                        .foregroundStyle(.teal.opacity(0.18))
                        .stroke(.teal, lineWidth: 2)
                }
                if let playbackPosition {
                    Annotation("Posición", coordinate: playbackPosition) {
                        Circle().fill(.blue).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .onAppear { camera = .region(initialRegion()) }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(playbackDate, format: .dateTime.day().month().hour().minute().second())
                        .font(.headline.monospacedDigit())
                    Spacer()
                    Text(DurationFormat.full(elapsed))
                        .font(.caption.monospacedDigit())
                }
                Slider(value: $elapsed, in: 0...max(1, episode.duration))
                    .accessibilityLabel("Posición temporal del recorrido")
                HStack {
                    Button(playing ? "Pausar" : "Reproducir") {
                        if elapsed >= episode.duration { elapsed = 0 }
                        playing.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Reiniciar") { playing = false; elapsed = 0 }
                        .buttonStyle(.bordered)
                    Spacer()
                    Picker("Velocidad", selection: $speed) {
                        Text("×1").tag(1.0)
                        Text("×10").tag(10.0)
                        Text("×60").tag(60.0)
                        Text("×360").tag(360.0)
                    }.pickerStyle(.menu)
                }
                Toggle("Mostrar trayecto GPS", isOn: $showRoute)
                VStack(alignment:.leading,spacing:4) {
                    Text("TIEMPO HISTÓRICO DE ESTA CUADRÍCULA")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    HStack(alignment:.firstTextBaseline) {
                        Text(cell == nil ? "—" : DurationFormat.full(accumulated))
                            .font(.headline.monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(cell == nil ? Color.orange : Color.teal)
                        Spacer(minLength:4)
                        if cell == nil {
                            Image(systemName:"location.slash").foregroundStyle(.orange)
                        }
                    }
                }
                .frame(height:48,alignment:.topLeading)
                Text("No se unen tramos separados por huecos GPS ni saltos imposibles.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle(episode.kind.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(ticker) { _ in
            guard playing else { return }
            elapsed = min(episode.duration, elapsed + 0.25 * speed)
            if elapsed >= episode.duration { playing = false }
        }
    }
}
