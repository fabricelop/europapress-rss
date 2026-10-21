import Foundation
import UIKit
import MapKit

/// A local raster projection of the latest radar mosaic. There are no
/// future API calls or invented future frames. MapKit remains freely zoomable.
final class RainFutureTiles: MKTileOverlay {
    let projection: RadarProjection
    let futureMinutes: Int
    private let rendered = NSCache<NSString, NSData>()

    init(projection: RadarProjection, futureMinutes: Int) {
        self.projection = projection
        self.futureMinutes = futureMinutes
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 19
        canReplaceMapContent = false
        rendered.countLimit = 130
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        URL(string: "https://raineta.local/projection/\(futureMinutes)/\(path.z)/\(path.x)/\(path.y).png")!
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let key = "\(path.z):\(path.x):\(path.y):\(futureMinutes)" as NSString
        if let cached = rendered.object(forKey: key) {
            result(cached as Data, nil)
            return
        }
        let p = projection
        let targetMinute = futureMinutes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let unit = pow(2.0, Double(7-path.z)) // z7 world pixels / on-screen pixel
            let worldX = Double(path.x) * 256 * unit
            let worldY = Double(path.y) * 256 * unit
            let factor = Double(targetMinute) / max(1, p.frameStep)
            let translatedX = p.worldOriginX + p.dx * factor
            let translatedY = p.worldOriginY + p.dy * factor
            let rect = CGRect(x: (translatedX-worldX)/unit,
                              y: (translatedY-worldY)/unit,
                              width: Double(p.image.size.width)/unit,
                              height: Double(p.image.size.height)/unit)
            // Offscreen tiles are transparent. The base map stays visible.
            guard rect.intersects(CGRect(x: 0, y: 0, width: 256, height: 256)) else {
                // MapKit expects an actual decodable PNG, not an empty Data.
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = false
                let blank = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256),
                                                    format: format).image { _ in }
                result(blank.pngData(), nil)
                return
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let raster = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
                .image { _ in
                    p.image.draw(in: rect, blendMode: .normal,
                                 alpha: CGFloat(p.opacity(at: targetMinute)))
                }
            guard let png = raster.pngData() else {
                result(nil, URLError(.cannotDecodeContentData))
                return
            }
            self?.rendered.setObject(png as NSData, forKey: key)
            result(png, nil)
        }
    }
}
