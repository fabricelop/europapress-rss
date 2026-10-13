import SwiftUI
import MapKit

final class RainRadarTiles: MKTileOverlay {
    let radarHost: String
    let radarPath: String

    init(host: String, path: String) {
        radarHost = host
        radarPath = path
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 15
        canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        URL(string: "\(radarHost)\(radarPath)/256/\(path.z)/\(path.x)/\(path.y)/2/1_1.png")!
    }
}

struct RadarMap: UIViewRepresentable {
    var center: CLLocationCoordinate2D
    var host: String
    var framePath: String?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var radarPath: String?
        var center: CLLocationCoordinate2D?
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? RainRadarTiles { return MKTileOverlayRenderer(tileOverlay: tile) }
            return MKOverlayRenderer(overlay: overlay)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .standard
        map.showsUserLocation = true
        map.showsCompass = true
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 240_000, longitudinalMeters: 240_000), animated: false)
        context.coordinator.center = center
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.radarPath != framePath {
            for overlay in map.overlays { map.removeOverlay(overlay) }
            coordinator.radarPath = framePath
            if let framePath, !host.isEmpty {
                map.addOverlay(RainRadarTiles(host: host, path: framePath), level: .aboveRoads)
            }
        }
        if let old = coordinator.center {
            let meters = CLLocation(latitude: old.latitude, longitude: old.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            if meters > 1500 {
                map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: 240_000, longitudinalMeters: 240_000), animated: true)
                coordinator.center = center
            }
        } else {
            coordinator.center = center
        }
    }
}
