import XCTest
import MapKit
import CoreLocation
@testable import RainETA

final class ICONForecastOverlayTests: XCTestCase {
    func testForecastUTCValidHourIsQuantizedNotFictitiousFiveMinutes() {
        let stamp = Date(timeIntervalSince1970: 1_800_000_001)
        let oneHour = ICONForecastTiles.forecastTime(leadMinutes: 60, now: stamp)
        XCTAssertEqual(oneHour.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600), 0)
        XCTAssertGreaterThanOrEqual(oneHour.timeIntervalSince(stamp), 3600)
        XCTAssertLessThan(oneHour.timeIntervalSince(stamp), 7200)
    }

    func testVisualHandoverIsMonotonicAndFullyModelAt30Minutes() {
        let steps=[0,5,10,15,20,25,30,45,120]
            .map {ICONForecastTiles.transitionWeight(leadMinutes:$0)}
        XCTAssertEqual(steps[0],0,accuracy:0.0001)
        XCTAssertEqual(steps[1],1.0/6.0,accuracy:0.0001)
        XCTAssertEqual(steps[3],0.5,accuracy:0.0001)
        XCTAssertEqual(steps[6],1,accuracy:0.0001)
        XCTAssertEqual(steps[8],1,accuracy:0.0001)
        XCTAssertEqual(steps,steps.sorted())
    }

    func testForecastPreloadOnlyNeedsAtMostNineVisibleTiles() {
        let map=MKMapView(frame:CGRect(x:0,y:0,width:390,height:325))
        map.setRegion(MKCoordinateRegion(
            center:CLLocationCoordinate2D(latitude:49.8,longitude:18.3),
            latitudinalMeters:240_000,longitudinalMeters:240_000),animated:false)
        let paths=RadarMap.requiredPaths(map)
        XCTAssertFalse(paths.isEmpty)
        XCTAssertLessThanOrEqual(paths.count,9)
        XCTAssertTrue(paths.allSatisfy{(0...16).contains($0.z)})
    }

    func testOfficialWMSRequestsValidMercatorTilesAtHighZoom() {
        let hour = Date(timeIntervalSince1970: 1_800_000_000)
        for z in [6,9,12,16] {
            let n = pow(2.0, Double(z))
            let x = Int((5.1+180)/360*n)
            let latitude = 52.1 * Double.pi / 180
            let y = Int((1 - asinh(tan(latitude))/Double.pi)/2*n)
            let path = MKTileOverlayPath(x:x,y:y,z:z,contentScaleFactor:1)
            guard let url = ICONForecastTiles.urlForTile(path, at: hour) else {
                XCTFail("No WMS URL at zoom \(z)")
                continue
            }
            let parts = URLComponents(url:url,resolvingAgainstBaseURL:false)
            let values = Dictionary(uniqueKeysWithValues:(parts?.queryItems ?? [])
                .compactMap { item -> (String,String)? in
                    guard let value=item.value else { return nil }
                    return (item.name,value)
                })
            XCTAssertEqual(values["SERVICE"], "WMS")
            XCTAssertEqual(values["REQUEST"], "GetMap")
            XCTAssertEqual(values["LAYERS"], "dwd:Icon-eu_reg00625_fd_sl_TOTPREC01H")
            XCTAssertEqual(values["SRS"], "EPSG:3857")
            XCTAssertEqual(values["TRANSPARENT"], "TRUE")
            XCTAssertNotNil(values["BBOX"])
            XCTAssertTrue(values["TIME"]?.hasSuffix("Z") ?? false)
        }
    }

    func testModelNeverClaimsCoverageOutsideEuropeanRegion() {
        XCTAssertTrue(ICONForecastTiles.covers(CLLocationCoordinate2D(latitude:40.4,longitude:-3.7)))
        XCTAssertTrue(ICONForecastTiles.covers(CLLocationCoordinate2D(latitude:52.1,longitude:5.1)))
        XCTAssertFalse(ICONForecastTiles.covers(CLLocationCoordinate2D(latitude:1.4,longitude:103.8)))
    }
}
