import XCTest
import MapKit
@testable import MiMapaDelTiempo

final class TimeZoneLabelLayoutTests: XCTestCase {
    private func overlay(_ name: String, latitude: Double,
                         longitude: Double) -> TimeZoneOverlay {
        TimeZoneOverlay(zone: TimeCustomZone(name:name,cellIDs:["10:20"]),
                        contours:[],
                        center:CLLocationCoordinate2D(latitude:latitude,longitude:longitude))
    }
    func testNearbyZoneNamesNeverOverlapAndFocusedZoneWins() {
        let a = overlay("Montevalle",latitude:40.4500,longitude:-3.7000)
        let b = overlay("Casa Montevalle",latitude:40.4502,longitude:-3.6998)
        let far = overlay("Pádel La Masó",latitude:40.454,longitude:-3.6955)
        let region = MKCoordinateRegion(
            center:CLLocationCoordinate2D(latitude:40.451,longitude:-3.699),
            span:MKCoordinateSpan(latitudeDelta:0.015,longitudeDelta:0.015))
        let ids = TimeZoneLabelLayout.visibleIDs([a,b,far],
                    viewport:region,preferredZoneID:b.zone.id)
        XCTAssertTrue(ids.contains(b.id))
        XCTAssertFalse(ids.contains(a.id))
        XCTAssertTrue(ids.contains(far.id))
        XCTAssertEqual(ids.count,2)
    }
    func testNearbyZonesShowBothAtSufficientZoom() {
        let a = overlay("Casa",latitude:40.4500,longitude:-3.7000)
        let b = overlay("Parque",latitude:40.4502,longitude:-3.6998)
        let region = MKCoordinateRegion(
            center:CLLocationCoordinate2D(latitude:40.4501,longitude:-3.6999),
            span:MKCoordinateSpan(latitudeDelta:0.0003,longitudeDelta:0.0003))
        XCTAssertEqual(TimeZoneLabelLayout.visibleIDs([a,b],viewport:region).count,2)
    }
    func testInvalidViewportDoesNotRenderLabels() {
        let item = overlay("Zona",latitude:40.45,longitude:-3.7)
        let invalid = MKCoordinateRegion(
            center:CLLocationCoordinate2D(latitude:40.45,longitude:-3.7),
            span:MKCoordinateSpan(latitudeDelta:0,longitudeDelta:0))
        XCTAssertTrue(TimeZoneLabelLayout.visibleIDs([item],viewport:invalid).isEmpty)
    }
}
