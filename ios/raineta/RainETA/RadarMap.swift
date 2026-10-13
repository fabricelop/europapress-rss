import SwiftUI
import MapKit
import UIKit

// RainViewer limits its API to zoom 7. Above that level we overzoom cached
// parent tiles locally, preserving MapKit's normal street-level map zoom.
final class RainRadarTiles: MKTileOverlay {
    let radarHost: String
    let radarPath: String
    var onFirstTile: (() -> Void)?
    private var hasReportedTile = false
    private func reportTileLoaded() {
        DispatchQueue.main.async {
            guard !self.hasReportedTile else { return }
            self.hasReportedTile = true
            self.onFirstTile?()
        }
    }
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
                reportTileLoaded()
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
            reportTileLoaded()
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
    var projection: RadarProjection?
    var modelField: FutureRainField?
    var futureMinutes: Int = 0
    var onViewport: ((CLLocationCoordinate2D,Double,Double)->Void)?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var observedKey: String?
        var futureKey: String?
        var center: CLLocationCoordinate2D?
        var onViewport: ((CLLocationCoordinate2D,Double,Double)->Void)?
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            onViewport?(region.center,region.span.latitudeDelta,region.span.longitudeDelta)
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? RainRadarTiles { return MKTileOverlayRenderer(tileOverlay: tile) }
            if let tile = overlay as? ModelRainTiles { return MKTileOverlayRenderer(tileOverlay: tile) }
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
        context.coordinator.onViewport = onViewport
        DispatchQueue.main.async { [weak map] in
            guard let map else { return }
            let span = map.region.span
            self.onViewport?(map.region.center,span.latitudeDelta,span.longitudeDelta)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onViewport = onViewport
        // Preserve a genuinely observed frame underneath a projected frame.
        // Do not remove the previous historical raster until the new one
        // delivers its first valid tile (avoids an empty map at AHORA).
        let observationKey = host + "|" + (framePath ?? "")
        if coordinator.observedKey != observationKey {
            coordinator.observedKey = observationKey
            if let framePath, !host.isEmpty {
                let previous = map.overlays.compactMap { $0 as? RainRadarTiles }
                let newest = RainRadarTiles(host: host, path: framePath)
                newest.onFirstTile = { [weak map] in
                    guard let map, map.overlays.contains(where: { $0 === newest }) else { return }
                    for layer in previous { map.removeOverlay(layer) }
                    newest.onFirstTile = nil
                }
                map.addOverlay(newest, level: .aboveRoads)
            }
        }
        let available = modelField != nil && futureMinutes > 0 &&
                        modelField!.times.first.map { Date().addingTimeInterval(Double(futureMinutes)*60) >= $0 } == true &&
                        modelField!.times.last.map { Date().addingTimeInterval(Double(futureMinutes)*60) <= $0 } == true
        let futureKey = available ?
            "model:\(futureMinutes):\(modelField!.fetchedAt.timeIntervalSince1970)" : "observed"
        if coordinator.futureKey != futureKey {
            coordinator.futureKey = futureKey
            let previousFuture = map.overlays.filter { $0 is ModelRainTiles || $0 is RainFutureTiles }
            if available, let modelField {
                map.addOverlay(ModelRainTiles(field:modelField,leadMinutes:futureMinutes),
                               level:.aboveRoads)
            }
            for layer in previousFuture { map.removeOverlay(layer) }
        }
        // Blend observational radar into a REAL model precipitation map.
        // No time-only fade unless the replacement field exists. Model rain
        // continues independently when the old radar imagery fades out.
        let radarAlpha:CGFloat = available ?
            CGFloat(max(0,1-Double(futureMinutes)/30.0)) : 1
        for overlay in map.overlays where overlay is RainRadarTiles {
            if let renderer = map.renderer(for:overlay),
               abs(renderer.alpha-radarAlpha) > 0.01 {
                renderer.alpha = radarAlpha
                renderer.setNeedsDisplay()
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
