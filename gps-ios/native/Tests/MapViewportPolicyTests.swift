import XCTest
import MapKit
@testable import MiMapaDelTiempo

final class MapViewportPolicyTests: XCTestCase {
    private let saved = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.4168, longitude: -3.7038),
        span: MKCoordinateSpan(latitudeDelta: 0.009, longitudeDelta: 0.009))

    func testTinyMapKitStartupCorrectionsDoNotTriggerCameraPersistence() {
        let jitter = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.416801, longitude: -3.703799),
            span: MKCoordinateSpan(latitudeDelta: 0.009002, longitudeDelta: 0.009001))
        XCTAssertFalse(MapViewportPolicy.meaningfulChange(from: saved, to: jitter))
    }

    func testGenuinePanAndZoomRemainResponsive() {
        let moved = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.417, longitude: -3.7038),
            span: saved.span)
        let zoomed = MKCoordinateRegion(
            center: saved.center,
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004))
        XCTAssertTrue(MapViewportPolicy.meaningfulChange(from: saved, to: moved))
        XCTAssertTrue(MapViewportPolicy.meaningfulChange(from: saved, to: zoomed))
    }

    func testInvalidCameraCannotReplaceSavedViewport() {
        let bad = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: .nan, longitude: -3.7038),
            span: saved.span)
        XCTAssertFalse(MapViewportPolicy.meaningfulChange(from: saved, to: bad))
    }
}
