import SwiftUI
import MapKit

/// Representación MapKit estable: no destruimos/recreamos todos los polígonos
/// y etiquetas en cada actualización SwiftUI ni en cada gesto del usuario.
struct BioGridStableMap: UIViewRepresentable {
    let populations: [String: [Int64]]
    let fingerprint: String
    let palette: [Color]
    let opacity: Double
    let highlighted: Int?
    let initialRegion: MKCoordinateRegion
    let focusCell: Cell?
    let focusToken: Int
    let onSelect: (Cell) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .standard
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.setRegion(initialRegion, animated: false)
        let recognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didTap(_:)))
        recognizer.cancelsTouchesInView = false
        map.addGestureRecognizer(recognizer)
        context.coordinator.synchronize(map, force: true)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.configuration = self
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            if let cell = focusCell {
                var next = map.region
                next.center = Grid.center(cell)
                next.span.latitudeDelta = min(next.span.latitudeDelta, 0.008)
                next.span.longitudeDelta = min(next.span.longitudeDelta, 0.008)
                map.setRegion(next, animated: true)
            }
        }
        context.coordinator.synchronize(map, force: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var configuration: BioGridStableMap
        var lastFocusToken: Int
        private var lastFingerprint = ""
        private var lastOpacity = -1.0
        private var lastHighlighted: Int?
        private var polygons: [String: BioGridPolygon] = [:]
        private var labels: [String: BioGridMapLabel] = [:]
        private let names = ["L", "M", "X", "J", "V", "S", "D"]

        init(_ configuration: BioGridStableMap) {
            self.configuration = configuration
            self.lastFocusToken = configuration.focusToken
        }

        @objc func didTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let map = gesture.view as? MKMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            let cell = Grid.cell(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let population = configuration.populations[cell.id],
               population.contains(where: { $0 > 0 }) {
                configuration.onSelect(cell)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            synchronize(mapView, force: true)
        }

        private func keyToCell(_ key: String) -> Cell? {
            let parts = key.split(separator: ":")
            guard parts.count == 2,
                  let r = Int(parts[0]), let c = Int(parts[1]) else { return nil }
            return Cell(row: r, column: c)
        }

        private func compact(_ value: Int64) -> String {
            if value >= 1_000_000 {
                return String(format: "%.2fM", Double(value) / 1_000_000)
            }
            if value >= 1_000 {
                return String(format: "%.1fK", Double(value) / 1_000)
            }
            return String(value)
        }

        func synchronize(_ map: MKMapView, force: Bool) {
            let changedSource = lastFingerprint != configuration.fingerprint
            let changedStyle = abs(lastOpacity - configuration.opacity) > 0.001
                || lastHighlighted != configuration.highlighted
            // El mapa gestiona su propia cámara y solo reconstruye las piezas
            // que salen o entran en la pantalla.
            if !force && !changedSource && !changedStyle { return }
            lastFingerprint = configuration.fingerprint
            lastOpacity = configuration.opacity
            lastHighlighted = configuration.highlighted

            let region = map.region
            let halfLat = region.span.latitudeDelta * 0.58
            let halfLon = region.span.longitudeDelta * 0.58
            let center = region.center
            var candidates: [(String, Cell, Int, Int64, Double)] = []
            for (key, counts) in configuration.populations {
                guard let cell = keyToCell(key),
                      let maximum = counts.max(), maximum > 0,
                      let family = counts.firstIndex(of: maximum) else { continue }
                let loc = Grid.center(cell)
                let latDistance = abs(loc.latitude - center.latitude)
                let lonDistance = abs(loc.longitude - center.longitude)
                guard latDistance <= halfLat && lonDistance <= halfLon else { continue }
                candidates.append((key, cell, family, maximum,
                    latDistance / max(halfLat, 0.000001)
                    + lonDistance / max(halfLon, 0.000001)))
            }
            if candidates.count > 2_000 {
                candidates.sort { $0.4 < $1.4 }
                candidates = Array(candidates.prefix(2_000))
            }

            let desired = Set(candidates.map { $0.0 })
            let removePolygons = polygons.filter { key, poly in
                !desired.contains(key) ||
                    candidates.contains(where: { $0.0 == key && $0.2 != poly.family })
            }
            for (key, _) in removePolygons { polygons.removeValue(forKey: key) }
            if !removePolygons.isEmpty {
                map.removeOverlays(removePolygons.map { $0.value })
            }

            var additions: [MKOverlay] = []
            for (key, cell, family, _, _) in candidates where polygons[key] == nil {
                var points = Grid.polygon(cell)
                let polygon = BioGridPolygon(coordinates: &points, count: points.count)
                polygon.family = family
                polygons[key] = polygon
                additions.append(polygon)
            }
            if !additions.isEmpty { map.addOverlays(additions, level: .aboveRoads) }

            let showText = region.span.latitudeDelta < 0.012
            let labelKeys = showText ? desired : Set<String>()
            let staleLabels = labels.filter { !labelKeys.contains($0.key) }
            for (key, _) in staleLabels { labels.removeValue(forKey: key) }
            if !staleLabels.isEmpty { map.removeAnnotations(staleLabels.map { $0.value }) }

            var addedLabels: [MKAnnotation] = []
            for (key, cell, family, maximum, _) in candidates where showText {
                let title = "\(names[family]) \(compact(maximum))"
                if let label = labels[key] {
                    if label.display != title {
                        label.display = title
                        if let view = map.view(for: label),
                           let text = view.viewWithTag(745) as? UILabel {
                            text.text = title
                        }
                    }
                } else {
                    let label = BioGridMapLabel()
                    label.coordinate = Grid.center(cell)
                    label.display = title
                    labels[key] = label
                    addedLabels.append(label)
                }
            }
            if !addedLabels.isEmpty { map.addAnnotations(addedLabels) }

            if changedStyle {
                for poly in polygons.values {
                    if let renderer = map.renderer(for: poly) as? MKPolygonRenderer {
                        applyStyle(to: renderer, family: poly.family)
                        renderer.setNeedsDisplay()
                    }
                }
            }
        }

        private func applyStyle(to renderer: MKPolygonRenderer, family: Int) {
            guard configuration.palette.indices.contains(family) else { return }
            let base = UIColor(configuration.palette[family])
            let intensity = configuration.highlighted == nil ||
                configuration.highlighted == family ? configuration.opacity : configuration.opacity * 0.16
            renderer.fillColor = base.withAlphaComponent(intensity)
            renderer.strokeColor = UIColor.black.withAlphaComponent(0.28)
            renderer.lineWidth = 0.5
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? BioGridPolygon else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolygonRenderer(polygon: polygon)
            applyStyle(to: renderer, family: polygon.family)
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let textAnnotation = annotation as? BioGridMapLabel else { return nil }
            let reuseID = "biogrid-label"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation = annotation
            view.frame = CGRect(x: 0, y: 0, width: 72, height: 16)
            view.backgroundColor = .clear
            view.canShowCallout = false
            view.isEnabled = false
            let text: UILabel
            if let existing = view.viewWithTag(745) as? UILabel {
                text = existing
            } else {
                text = UILabel(frame: view.bounds)
                text.tag = 745
                text.textAlignment = .center
                text.font = .boldSystemFont(ofSize: 10)
                text.textColor = .black
                text.backgroundColor = .clear
                text.adjustsFontSizeToFitWidth = true
                text.minimumScaleFactor = 0.6
                text.isUserInteractionEnabled = false
                view.addSubview(text)
            }
            text.frame = view.bounds
            text.text = textAnnotation.display
            return view
        }
    }
}

private final class BioGridPolygon: MKPolygon {
    var family = 0
}

private final class BioGridMapLabel: MKPointAnnotation {
    var display = ""
}
