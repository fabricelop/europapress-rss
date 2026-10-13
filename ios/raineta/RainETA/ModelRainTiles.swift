import Foundation
import UIKit
import MapKit

/// A pixel tile drawn from georeferenced numerical-forecast precipitation.
/// Unlike a scaled RainViewer raster, it is computed at any MapKit zoom.
final class ModelRainTiles: MKTileOverlay {
    let field: FutureRainField
    let targetDate: Date
    private let cache = NSCache<NSString, NSData>()
    let leadMinutes: Int

    init(field: FutureRainField, leadMinutes: Int) {
        self.field = field
        self.leadMinutes = leadMinutes
        self.targetDate = Date().addingTimeInterval(Double(leadMinutes)*60)
        super.init(urlTemplate:nil)
        tileSize = CGSize(width:256,height:256)
        minimumZ = 0
        maximumZ = 20
        canReplaceMapContent = false
        cache.countLimit = 140
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        URL(string:"https://raineta.invalid/model/\(leadMinutes)/\(path.z)/\(path.x)/\(path.y).png")!
    }

    /// Model frame interpolation takes place in global Web Mercator space.
    /// No alpha fade is used to simulate temporal evolution: rain appears,
    /// moves and dissipates according to the model values themselves.
    func image(forTile path: MKTileOverlayPath) -> UIImage {
        let steps = 64
        let side = CGFloat(256)
        let scale = pow(2.0, Double(path.z))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size:CGSize(width:256,height:256),format:format).image { context in
            let cg = context.cgContext
            cg.clear(CGRect(x:0,y:0,width:256,height:256))
            for row in 0..<steps {
                for col in 0..<steps {
                    let worldX = (Double(path.x)+(Double(col)+0.5)/Double(steps))/scale
                    let worldY = (Double(path.y)+(Double(row)+0.5)/Double(steps))/scale
                    guard let rate = field.rate(x:worldX,y:worldY,date:targetDate),
                          rate >= 0.12 else { continue }
                    let color: UIColor
                    switch rate {
                    case ..<0.4: color = UIColor(red:0.32,green:0.78,blue:1,alpha:0.42)
                    case ..<1.5: color = UIColor(red:0.06,green:0.6,blue:0.95,alpha:0.66)
                    case ..<3.5: color = UIColor(red:0.04,green:0.28,blue:0.87,alpha:0.74)
                    case ..<7.5: color = UIColor(red:0.98,green:0.82,blue:0.07,alpha:0.82)
                    case ..<15: color = UIColor(red:1,green:0.46,blue:0.04,alpha:0.86)
                    default: color = UIColor(red:0.91,green:0.07,blue:0.17,alpha:0.89)
                    }
                    cg.setFillColor(color.cgColor)
                    cg.fill(CGRect(x: CGFloat(col)*side/CGFloat(steps),
                                   y: CGFloat(row)*side/CGFloat(steps),
                                   width:side/CGFloat(steps)+0.15,
                                   height:side/CGFloat(steps)+0.15))
                }
            }
        }
    }

    override func loadTile(at path:MKTileOverlayPath,
                           result:@escaping (Data?,Error?)->Void) {
        let key = "\(path.z):\(path.x):\(path.y)" as NSString
        if let data = cache.object(forKey:key) {
            result(data as Data,nil)
            return
        }
        DispatchQueue.global(qos:.userInitiated).async {
            let png = self.image(forTile:path).pngData()
            if let png {
                self.cache.setObject(png as NSData,forKey:key)
                result(png,nil)
            } else {
                result(nil,URLError(.cannotDecodeContentData))
            }
        }
    }
}
