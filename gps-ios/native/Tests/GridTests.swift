import XCTest
import CoreLocation
@testable import MiMapaDelTiempo

final class GridTests: XCTestCase {
    func testSameCoordinateAlwaysUsesSameCell() {
        let a = Grid.cell(latitude: 40.4168, longitude: -3.7038)
        XCTAssertEqual(a, Grid.cell(latitude: 40.4168, longitude: -3.7038))
    }
    func testCenterFallsInsideItsCell() {
        for (lat, lon) in [(40.4168, -3.7038), (48.8566, 2.3522),
                           (-33.8688, 151.2093), (0.0, 0.0)] {
            let cell = Grid.cell(latitude: lat, longitude: lon)
            let center = Grid.center(cell)
            XCTAssertEqual(Grid.cell(latitude: center.latitude, longitude: center.longitude), cell)
        }
    }
    func testApproximateSizeNearMadrid() {
        let cell = Grid.cell(latitude: 40.4168, longitude: -3.7038)
        let p = Grid.polygon(cell)
        let horizontal = CLLocation(latitude: p[0].latitude, longitude: p[0].longitude)
            .distance(from: CLLocation(latitude: p[1].latitude, longitude: p[1].longitude))
        let vertical = CLLocation(latitude: p[0].latitude, longitude: p[0].longitude)
            .distance(from: CLLocation(latitude: p[3].latitude, longitude: p[3].longitude))
        XCTAssertEqual(horizontal, 100, accuracy: 3)
        XCTAssertEqual(vertical, 100, accuracy: 3)
    }
    func testMonthDurationIsExactlyThirtyDays() {
        XCTAssertEqual(DurationFormat.full(2_592_000), "1M-0D-0H:0m:0sg")
        XCTAssertEqual(DurationFormat.full(3_661), "0M-0D-1H:1m:1sg")
    }
}
