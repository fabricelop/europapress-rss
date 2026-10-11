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
    @State private var camera: MapCameraPosition = .automatic
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var playbackDate: Date { episode.start.addingTimeInterval(elapsed) }

    private var playbackPosition: CLLocationCoordinate2D {
        let points = episode.points
        guard let first = points.first else { return .init(latitude: 0, longitude: 0) }
        if playbackDate <= first.date || points.count == 1 {
            return .init(latitude: first.latitude, longitude: first.longitude)
        }
        for index in points.indices.dropFirst() {
            let b = points[index]
            if playbackDate <= b.date {
                let a = points[index - 1]
                let span = max(0.001, b.date.timeIntervalSince(a.date))
                let fraction = min(1, max(0, playbackDate.timeIntervalSince(a.date) / span))
                return .init(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                             longitude: a.longitude + (b.longitude - a.longitude) * fraction)
            }
        }
        let last = points[points.count - 1]
        return .init(latitude: last.latitude, longitude: last.longitude)
    }

    private var cell: Cell {
        Grid.cell(latitude: playbackPosition.latitude, longitude: playbackPosition.longitude)
    }

    private var accumulated: TimeInterval {
        intervals.reduce(0) { sum, segment in
            guard segment.cell == cell && segment.start < playbackDate else { return sum }
            return sum + max(0, min(segment.end, playbackDate).timeIntervalSince(segment.start))
        }
    }

    private var route: [CLLocationCoordinate2D] {
        episode.points.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
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
                if route.count > 1 {
                    MapPolyline(coordinates: route)
                        .stroke(.blue, lineWidth: 3)
                }
                MapPolygon(coordinates: Grid.polygon(cell))
                    .foregroundStyle(.teal.opacity(0.18))
                    .stroke(.teal, lineWidth: 2)
                Annotation("Posición", coordinate: playbackPosition) {
                    Circle().fill(.blue).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
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
                LabeledContent("Tiempo histórico de esta cuadrícula",
                               value: DurationFormat.full(accumulated))
                    .font(.caption)
                Text("La línea entre posiciones GPS es aproximada; no se rellenan intervalos sin señal.")
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
