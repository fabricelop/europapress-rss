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
    var recenterRevision: Int = 0
    var forecastStatus: ((String) -> Void)?
    var onViewport: ((CLLocationCoordinate2D,Double,Double)->Void)?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var observedKey: String?
        var futureKey: String?
        var forecastTask: Task<Void,Never>?
        var lastRecenter = 0
        var center: CLLocationCoordinate2D?
        var onViewport: ((CLLocationCoordinate2D,Double,Double)->Void)?
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            onViewport?(region.center,region.span.latitudeDelta,region.span.longitudeDelta)
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? RainRadarTiles { return MKTileOverlayRenderer(tileOverlay: tile) }
            if let tile = overlay as? ICONForecastTiles { return MKTileOverlayRenderer(tileOverlay: tile) }
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
        context.coordinator.lastRecenter = recenterRevision
        context.coordinator.onViewport = onViewport
        DispatchQueue.main.async { [weak map] in
            guard let map else { return }
            let span = map.region.span
            self.onViewport?(map.region.center,span.latitudeDelta,span.longitudeDelta)
        }
        return map
    }

    /// Prepare the visible tile rectangle before a frame is revealed.
    /// The current 256px WMS tile set is cached in ICONForecastTiles.
    static func requiredPaths(_ map:MKMapView) -> [MKTileOverlayPath] {
        let world=MKMapRect.world.size.width
        let extent=map.visibleMapRect
        guard map.bounds.width>0,extent.size.width>0 else {
            let point=MKMapPoint(map.centerCoordinate)
            let scale=pow(2.0,7.0)
            return [MKTileOverlayPath(x:Int(point.x/world*scale),
                                      y:Int(point.y/world*scale),z:7,contentScaleFactor:1)]
        }
        let zoom=max(0,min(16,Int(round(log2(world/extent.size.width*
                                             Double(map.bounds.width)/256.0)))))
        let n=1<<zoom
        let minX=max(0,min(n-1,Int(floor(extent.minX/world*Double(n)))))
        let maxX=max(minX,min(n-1,Int(floor(extent.maxX/world*Double(n)))))
        let minY=max(0,min(n-1,Int(floor(extent.minY/world*Double(n)))))
        let maxY=max(minY,min(n-1,Int(floor(extent.maxY/world*Double(n)))))
        // Preloading is bounded; MapKit fetches further tiles normally on pan.
        let xEnd=min(maxX,minX+5)
        let yEnd=min(maxY,minY+5)
        return (minY...yEnd).flatMap { y in
            (minX...xEnd).map { x in
                MKTileOverlayPath(x:x,y:y,z:zoom,contentScaleFactor:1)
            }
        }
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
                    // New observed frames must remain hidden while a model
                    // forecast is currently visible above the basemap.
                    if map.overlays.contains(where:{$0 is ICONForecastTiles}),
                       let renderer=map.renderer(for:newest) {
                        renderer.alpha=0
                        renderer.setNeedsDisplay()
                    }
                    newest.onFirstTile = nil
                }
                map.addOverlay(newest, level: .aboveRoads)
                if map.overlays.contains(where:{$0 is ICONForecastTiles}),
                   let renderer=map.renderer(for:newest) {
                    renderer.alpha=0
                }
            }
        }
        // A generation token and cancellable preloading task prevent an old
        // async response from replacing the user's latest selected frame.
        let wantModel = futureMinutes > 0 && ICONForecastTiles.covers(center)
        let window = wantModel ? ICONForecastTiles.period(leadMinutes:futureMinutes) : nil
        let futureKey = window.map {
            "\(Int($0.lower.timeIntervalSince1970)):\(Int($0.fraction*1000))"
        } ?? "observed"
        if coordinator.futureKey != futureKey {
            coordinator.futureKey=futureKey
            coordinator.forecastTask?.cancel()
            coordinator.forecastTask=nil
            if let window {
                let tileLayer=ICONForecastTiles(validTime:window.lower,
                                                upperTime:window.upper,
                                                fraction:window.fraction,
                                                requestedTime:window.target)
                let paths=Self.requiredPaths(map)
                let desiredKey=futureKey
                coordinator.forecastTask=Task { @MainActor [weak map,weak coordinator] in
                    // Debounce rapid five-minute scrubbing without removing the
                    // currently displayed field.
                    try? await Task.sleep(nanoseconds:120_000_000)
                    guard !Task.isCancelled else{return}
                    let success=await tileLayer.prepare(paths)
                    guard !Task.isCancelled,let map,let coordinator,
                          coordinator.futureKey==desiredKey else{return}
                    if success {
                        let previous=map.overlays.filter {
                            $0 is ICONForecastTiles || $0 is ModelRainTiles || $0 is RainFutureTiles
                        }
                        tileLayer.onFirstTile={ [weak map,weak coordinator] in
                            guard let map,let coordinator,
                                  coordinator.futureKey==desiredKey,
                                  map.overlays.contains(where:{$0===tileLayer}) else{return}
                            for overlay in previous { map.removeOverlay(overlay) }
                            for overlay in map.overlays where overlay is RainRadarTiles {
                                if let renderer=map.renderer(for:overlay) {
                                    renderer.alpha=0
                                    renderer.setNeedsDisplay()
                                }
                            }
                            tileLayer.onFirstTile=nil
                        }
                        map.addOverlay(tileLayer,level:.aboveRoads)
                        forecastStatus?("ICON-EU · \(window.target.formatted(date:.omitted,time:.shortened))")
                    } else {
                        // Keep the last complete displayed overlay on error,
                        // rather than flashing a blank or only one tile.
                        forecastStatus?("Previsión temporalmente no disponible")
                    }
                }
            } else {
                for layer in map.overlays where layer is ICONForecastTiles ||
                          layer is ModelRainTiles || layer is RainFutureTiles {
                    map.removeOverlay(layer)
                }
                for layer in map.overlays where layer is RainRadarTiles {
                    if let renderer=map.renderer(for:layer) {
                        renderer.alpha=1
                        renderer.setNeedsDisplay()
                    }
                }
            }
        }
        if let old = coordinator.center {
            let meters = CLLocation(latitude: old.latitude, longitude: old.longitude)
                .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
            if meters > 1500 {
                // Switching saved location: reset to a useful regional view.
                map.setRegion(MKCoordinateRegion(center:center,latitudinalMeters:240_000,
                                                 longitudinalMeters:240_000),animated:true)
                coordinator.center=center
                coordinator.lastRecenter=recenterRevision
            } else if coordinator.lastRecenter != recenterRevision {
                // Manual centering keeps the user's selected zoom unchanged.
                map.setCenter(center,animated:true)
                coordinator.lastRecenter=recenterRevision
            }
        } else {
            coordinator.center = center
        }
    }
}
