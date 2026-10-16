import XCTest
import MapKit
@testable import MiMapaDelTiempo

/// Regression coverage for the exact gestures that previously stalled the map.
final class MapZoomStabilityTests: XCTestCase {
    private let madrid = CLLocationCoordinate2D(latitude: 40.4168, longitude: -3.7038)

    func testRepeatedZoomInKeepsFinitePositiveSpanAndOriginalCenter() {
        var region = MKCoordinateRegion(center: madrid,
            span: MKCoordinateSpan(latitudeDelta: 0.009, longitudeDelta: 0.009))
        for _ in 0..<30 {
            region = MapZoomPolicy.scaled(region, factor: 0.6, center: madrid)
            XCTAssertTrue(region.span.latitudeDelta.isFinite)
            XCTAssertGreaterThanOrEqual(region.span.latitudeDelta, 0.0004)
            XCTAssertGreaterThanOrEqual(region.span.longitudeDelta, 0.0004)
            XCTAssertEqual(region.center.latitude, madrid.latitude, accuracy: 1e-8)
            XCTAssertEqual(region.center.longitude, madrid.longitude, accuracy: 1e-8)
        }
    }

    func testZoomOutRemainsBoundedAndRecognized() {
        var region = MKCoordinateRegion(center: madrid,
            span: MKCoordinateSpan(latitudeDelta: 0.0004, longitudeDelta: 0.0004))
        for _ in 0..<60 {
            region = MapZoomPolicy.scaled(region, factor: 1.65, center: madrid)
        }
        XCTAssertLessThanOrEqual(region.span.latitudeDelta, 90)
        XCTAssertLessThanOrEqual(region.span.longitudeDelta, 90)
        let moved = MapZoomPolicy.scaled(region, factor: 0.6, center: madrid)
        XCTAssertTrue(MapViewportPolicy.meaningfulChange(from: region, to: moved))
    }

    func testCloseZoomCameraJitterDoesNotResetSavedViewport() {
        let original = MKCoordinateRegion(center: madrid,
            span: MKCoordinateSpan(latitudeDelta: 0.0004, longitudeDelta: 0.0004))
        let jitter = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: madrid.latitude + 0.00000001,
                                           longitude: madrid.longitude - 0.00000001),
            span: MKCoordinateSpan(latitudeDelta: 0.00040002,
                                   longitudeDelta: 0.00040002))
        XCTAssertFalse(MapViewportPolicy.meaningfulChange(from: original, to: jitter))
    }

    func testGridBoundariesNearFineZoomMapToVisitedCell() {
        let here = Grid.cell(latitude: madrid.latitude, longitude: madrid.longitude)
        let center = Grid.center(here)
        XCTAssertEqual(Grid.cell(latitude: center.latitude, longitude: center.longitude), here)
        XCTAssertEqual(Grid.polygon(here).count, 4)
    }
}
