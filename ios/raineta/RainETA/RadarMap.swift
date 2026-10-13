import SwiftUI
import MapKit
import UIKit

// RainViewer limits its API to zoom 7. Above that level we overzoom cached
// parent tiles locally, preserving MapKit's normal street-level map zoom.
final class RainRadarTiles: MKTileOverlay {
    let radarHost: String
    let radarPath: String
    private static let sharedTileCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 180
        return cache
    }()

    init(host: String, path: String) {
        radarHost = host
        radarPath = path
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 18
        canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let delta = max(0, path.z - 7)
        let factor = 1 << min(20, delta)
        let z = min(7, path.z)
        let x = path.x / factor
        let y = path.y / factor
        return URL(string: "\(radarHost)\(radarPath)/256/\(z)/\(x)/\(y)/2/1_1.png")!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let url = url(forTilePath: path)
        let key = url.absoluteString as NSString
        let requested = path

        func reply(_ source: Data) {
            guard requested.z > 7 else {
                result(source, nil)
                return
            }
            // Crop only the relevant part of the parent tile. Requests always
            // stay <= z7; at higher map zooms raster detail is necessarily limited.
            guard let image = UIImage(data: source)?.cgImage else {
                result(nil, URLError(.cannotDecodeContentData))
                return
            }
            let delta = min(20, requested.z - 7)
            let factor = 1 << delta
            let tileWidth = image.width
            let tileHeight = image.height
            let subX = requested.x % factor
            let subY = requested.y % factor
            let cellX = min(tileWidth - 1, Int(Double(subX) * Double(tileWidth) / Double(factor)))
            let cellY = min(tileHeight - 1, Int(Double(subY) * Double(tileHeight) / Double(factor)))
            let nextX = min(tileWidth, max(cellX + 1, Int(Double(subX + 1) * Double(tileWidth) / Double(factor))))
            let nextY = min(tileHeight, max(cellY + 1, Int(Double(subY + 1) * Double(tileHeight) / Double(factor))))
            let rect = CGRect(x: cellX, y: cellY, width: nextX - cellX, height: nextY - cellY)
            guard let clipped = image.cropping(to: rect) else {
                result(nil, URLError(.cannotDecodeContentData))
                return
            }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
            let rendered = renderer.image { _ in
                UIImage(cgImage: clipped).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            }
            result(rendered.pngData(), nil)
        }

        if let cached = Self.sharedTileCache.object(forKey: key) {
            reply(cached as Data)
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error { result(nil, error); return }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                result(nil, URLError(.badServerResponse))
                return
            }
            Self.sharedTileCache.setObject(data as NSData, forKey: key)
            reply(data)
        }.resume()
    }
}

struct RadarMap: UIViewRepresentable {
    var center: CLLocationCoordinate2D
    var host: String
    var framePath: String?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlayKey: String?
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
        let key = (framePath ?? "no-radar") + "|" + host
        if coordinator.overlayKey != key {
            for overlay in map.overlays { map.removeOverlay(overlay) }
            coordinator.overlayKey = key
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
