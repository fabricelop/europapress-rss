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
    var nowcastPath: String? = nil
    var recenterRevision: Int = 0
    var forecastStatus: ((String) -> Void)?
    var onViewport: ((CLLocationCoordinate2D,Double,Double)->Void)?
    var onForecastReady: ((Int,Bool)->Void)?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var observedKey: String?
        var futureKey: String?
        var forecastTask: Task<Void,Never>?
        var lastRecenter = 0
        var center: CLLocationCoordinate2D?
        var onViewport: ((CLLocationCoordinate2D,Double,Double)->Void)?
        var onForecastReady: ((Int,Bool)->Void)?
        var selectedLeadMinutes = 0
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
        context.coordinator.onForecastReady = onForecastReady
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
        let tilesPerScreen = world / extent.size.width * Double(map.bounds.width) / 256.0
        let zoom=max(0,min(16,Int(round(log2(tilesPerScreen)))))
        let n=1<<zoom
        let minX=max(0,min(n-1,Int(floor(extent.minX/world*Double(n)))))
        let maxX=max(minX,min(n-1,Int(floor(extent.maxX/world*Double(n)))))
        let minY=max(0,min(n-1,Int(floor(extent.minY/world*Double(n)))))
        let maxY=max(minY,min(n-1,Int(floor(extent.maxY/world*Double(n)))))
        // Preloading is bounded; MapKit fetches further tiles normally on pan.
        // Request centre-first and no more than nine cells. Previously a
        // 6x6 warm-up delayed every +5-minute step until 36 WMS renders
        // finished even when the screen only needed a few tiles.
        let midX=(minX+maxX)/2, midY=(minY+maxY)/2
        let all=(minY...maxY).flatMap { y in
            (minX...maxX).map { x in (x:x,y:y) }
        }
        return all.sorted {
            let a=abs($0.x-midX)+abs($0.y-midY)
            let b=abs($1.x-midX)+abs($1.y-midY)
            return a<b
        }.prefix(9).map {
            MKTileOverlayPath(x:$0.x,y:$0.y,z:zoom,contentScaleFactor:1)
        }
    }

    /// When a future frame exists, it belongs to the SAME precipitation
    /// compositor and colour palette as the observed frames. This eliminates
    /// the misleading WMS radar/ICON switch and WMS tile stalls.
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator=context.coordinator
        coordinator.onViewport=onViewport
        coordinator.onForecastReady=onForecastReady
        coordinator.selectedLeadMinutes=futureMinutes

        let selectedPath = futureMinutes>0 ? nowcastPath : framePath
        let key=host+"|"+(selectedPath ?? "")
        if coordinator.observedKey != key {
            coordinator.observedKey=key
            coordinator.forecastTask?.cancel()
            coordinator.forecastTask=nil
            guard let selectedPath, !host.isEmpty else {
                if futureMinutes>0 {forecastStatus?("Nowcast no disponible")}
                coordinator.onForecastReady?(futureMinutes,false)
                return
            }
            let oldLayers=map.overlays.compactMap {$0 as? RainRadarTiles}
            let incoming=RainRadarTiles(host:host,path:selectedPath)
            incoming.onFirstTile={ [weak map,weak coordinator] in
                guard let map,let coordinator,
                      coordinator.observedKey==key,
                      map.overlays.contains(where:{$0===incoming}) else{return}
                let newRenderer=map.renderer(for:incoming)
                newRenderer?.alpha=1
                newRenderer?.setNeedsDisplay()
                for layer in oldLayers {
                    map.removeOverlay(layer)
                }
                incoming.onFirstTile=nil
                if futureMinutes>0 {
                    coordinator.onForecastReady?(futureMinutes,true)
                }
            }
            map.addOverlay(incoming,level:.aboveRoads)
            // Retain the complete old precipitation map while the first tile
            // of the next actual/nowcast frame loads.
            if let renderer=map.renderer(for:incoming) {
                renderer.alpha=0
                renderer.setNeedsDisplay()
            }
            // A tile-server outage must not leave the playback spinner active.
            if futureMinutes>0 {
                coordinator.forecastTask=Task { @MainActor [weak map,weak coordinator] in
                    try? await Task.sleep(nanoseconds:6_000_000_000)
                    guard !Task.isCancelled,let map,let coordinator,
                          coordinator.observedKey==key,
                          incoming.onFirstTile != nil else{return}
                    map.removeOverlay(incoming)
                    coordinator.onForecastReady?(futureMinutes,false)
                    forecastStatus?("Nowcast temporalmente no disponible")
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
