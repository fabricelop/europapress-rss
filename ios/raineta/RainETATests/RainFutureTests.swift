import XCTest
import CoreLocation
import MapKit
@testable import RainETA

final class RainFutureTests: XCTestCase {
    private let madrid = CLLocationCoordinate2D(latitude: 40.4168, longitude:-3.7038)

    private func fixture() -> FutureRainField {
        let source = FutureRainField.makeTestField(center:madrid)
        let now = Date()
        return FutureRainField(columns:source.columns, rows:source.rows,
                               westX:source.westX,northY:source.northY,
                               eastX:source.eastX,southY:source.southY,
                               times:[now.addingTimeInterval(-900),now.addingTimeInterval(4*3600)],
                               values:source.values,fetchedAt:now,completeness:1)
    }

    func testFutureFieldActuallyChangesInSpaceAndTime() {
        let field = fixture()
        let now = field.times[0]
        let x = field.westX + 3.0/8.0*(field.eastX-field.westX)
        let y = field.northY + 4.0/8.0*(field.southY-field.northY)
        let before = field.rate(x:x,y:y,date:now)
        let after = field.rate(x:x,y:y,date:field.times[1])
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertGreaterThan(before!,after!+2)
        XCTAssertGreaterThan(field.rate(x:x,y:y,date:now.addingTimeInterval(300)) ?? 0,0)
        XCTAssertGreaterThan(field.rate(x:x,y:y,date:now.addingTimeInterval(600)) ?? 0,0)
    }

    func testZoom7_12_16AllProduceVisibleModelPrecipitation() {
        let field = fixture()
        let point = FutureRainField.worldPoint(madrid)
        for zoom in [7,12,16] {
            let width = pow(2.0,Double(zoom))
            let tile = MKTileOverlayPath(x:Int(point.x*width),y:Int(point.y*width),
                                         z:zoom,contentScaleFactor:1)
            let overlay = ModelRainTiles(field:field,leadMinutes:10)
            let png = overlay.image(forTile:tile).pngData()
            XCTAssertNotNil(png,"No tile at zoom \(zoom)")
            let image = UIImage(data:png!)!
            XCTAssertGreaterThan(wetPixels(image),0,"Rain disappeared at zoom \(zoom)")
        }
    }

    func testNowToFutureRemainsWetWhenModelShowsRain() {
        let field = fixture()
        let point = FutureRainField.worldPoint(madrid)
        let scale = pow(2.0,12.0)
        let tile = MKTileOverlayPath(x:Int(point.x*scale),y:Int(point.y*scale),
                                     z:12,contentScaleFactor:1)
        for lead in [5,10,15,30,60,120] {
            let output = ModelRainTiles(field:field,leadMinutes:lead).image(forTile:tile)
            XCTAssertGreaterThan(wetPixels(output),0,"Empty frame at future +\(lead)m")
        }
    }

    func testGeographicalBoundsNotImageZoomConstraint() {
        let field = fixture()
        let center = FutureRainField.worldPoint(madrid)
        XCTAssertNotNil(field.rate(x:center.x,y:center.y,date:field.times[0]))
        XCTAssertNil(field.rate(x:center.x+0.25,y:center.y,date:field.times[0]))
        XCTAssertNil(field.rate(x:center.x,y:center.y,
                                date:field.times[1].addingTimeInterval(3600)))
    }

    private func wetPixels(_ image:UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width,height = cg.height
        var pixels = [UInt8](repeating:0,count:width*height*4)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data:bytes.baseAddress,width:width,height:height,
                                      bitsPerComponent:8,bytesPerRow:width*4,
                                      space:CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
            return true
        }
        guard success else { return 0 }
        return stride(from:3,to:pixels.count,by:4).reduce(0) { $0+(pixels[$1]>0 ? 1:0) }
    }
}
