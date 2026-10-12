import XCTest
import MapKit
@testable import MiMapaDelTiempo

final class GPSFinalPolishTests:XCTestCase {
    func testGPSHealthDifferentiatesRestFromStale() {
        let now=Date(timeIntervalSince1970:1000)
        let last=Date(timeIntervalSince1970:600)
        XCTAssertEqual(GPSHealthAssessment.evaluate(recording:false,resting:true,
                        lastFix:last,now:now),.paused)
        XCTAssertEqual(GPSHealthAssessment.evaluate(recording:true,resting:false,
                        lastFix:last,now:now),.stale(400))
        XCTAssertEqual(GPSHealthAssessment.evaluate(recording:true,resting:false,
                        lastFix:now.addingTimeInterval(-30),now:now),.recent)
        XCTAssertEqual(GPSHealthAssessment.evaluate(recording:true,resting:false,
                        lastFix:now.addingTimeInterval(-85),now:now),.delayed(85))
        XCTAssertEqual(GPSHealthAssessment.evaluate(recording:true,resting:false,
                        lastFix:nil,now:now),.waiting)
    }
    func testZoomRetainsCenterAndRespectsBounds() {
        let center=CLLocationCoordinate2D(latitude:40.44,longitude:-3.72)
        let region=MKCoordinateRegion(center:center,
            span:MKCoordinateSpan(latitudeDelta:0.02,longitudeDelta:0.03))
        let nearer=MapZoomPolicy.scaled(region,factor:0.6,center:center)
        XCTAssertEqual(nearer.center.latitude,center.latitude,accuracy:0.000001)
        XCTAssertEqual(nearer.span.latitudeDelta,0.012,accuracy:0.000001)
        let farther=MapZoomPolicy.scaled(nearer,factor:1.65,center:center)
        XCTAssertEqual(farther.span.latitudeDelta,0.0198,accuracy:0.000001)
        XCTAssertGreaterThanOrEqual(MapZoomPolicy.scaled(region,
                       factor:0.00001,center:center).span.latitudeDelta,0.0004)
    }
}
