import XCTest
import Foundation
@testable import RainETA

final class OperaCOGTests: XCTestCase {
    func testEllipsoidalLAEAProjectionAgainstPROJ() {
        // Official OPERA COG projected CRS; numerical reference from PROJ.
        let samples:[(Double,Double,Double,Double)]=[
            (40.4168,-3.7038,785205.5913,-3608029.0227),
            (41.39,2.17,1292019.1071,-3574723.0293),
            (59.33,18.06,2407995.5829,-1591209.2559),
            (38.72,-9.14,289558.8968,-3686741.9632)
        ]
        for (lat,lon,x,y) in samples {
            guard let projected=OperaGeo.project(latitude:lat,longitude:lon) else {
                XCTFail("Point not projected");continue
            }
            XCTAssertEqual(projected.x,x,accuracy:0.2)
            XCTAssertEqual(projected.y,y,accuracy:0.2)
        }
    }

    func testRadarGridGeoreferencingForSpain() {
        let madrid=OperaGeo.rasterPosition(latitude:40.4168,longitude:-3.7038)
        XCTAssertNotNil(madrid)
        XCTAssertEqual(madrid!.column,785.7056,accuracy:0.02)
        XCTAssertEqual(madrid!.row,3608.529,accuracy:0.02)
        let faraway=OperaGeo.rasterPosition(latitude:0,longitude:0)
        XCTAssertNil(faraway)
    }

    func testDeterministic5MinuteUTCSourceLinks() {
        let stamp=Date(timeIntervalSince1970:1_799_999_700)
        let url=OperaCOGSource.URLForFrame(at:stamp)
        XCTAssertEqual(url.host,"s3.waw3-1.cloudferro.com")
        XCTAssertTrue(url.path.contains("/OPERA/COMP/"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix("@DBZH.tiff"))
        XCTAssertEqual(url.scheme,"https")
    }
}
