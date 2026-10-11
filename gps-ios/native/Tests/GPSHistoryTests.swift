import XCTest
@testable import MiMapaDelTiempo

final class GPSHistoryTests: XCTestCase {
    private func point(_ seconds: TimeInterval, _ lat: Double, _ lon: Double) -> GPSHistoryFix {
        GPSHistoryFix(date: Date(timeIntervalSince1970: seconds),
                      latitude: lat, longitude: lon)
    }

    func testGapIsNeverDrawnAsOneContinuousTrack() {
        let points = [
            point(0, 40.4168, -3.7038),
            point(60, 40.4169, -3.7039),
            point(500, 40.4170, -3.7040),
            point(560, 40.4171, -3.7041)
        ]
        let groups = GPSHistoryGrouping.chunks(points)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[1].count, 2)
    }

    func testStableGridNotAffectedByGrouping() {
        let a = point(0, 40.4168, -3.7038)
        let b = point(60, 40.4168, -3.7038)
        XCTAssertEqual(GPSHistoryGrouping.chunks([a, b]).count, 1)
        XCTAssertEqual(Grid.cell(latitude: a.latitude, longitude: a.longitude),
                       Grid.cell(latitude: b.latitude, longitude: b.longitude))
    }

    func testLargeJumpIsNotConsideredContinuous() {
        let a = point(0, 40.4168, -3.7038)
        let b = point(1, 48.8566, 2.3522)
        XCTAssertFalse(GPSHistoryGrouping.connected(a, b))
    }
}
