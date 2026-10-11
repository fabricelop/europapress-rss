import XCTest
@testable import MiMapaDelTiempo

final class GPSRouteSegmentsTests: XCTestCase {
    private func fix(_ seconds: TimeInterval, _ lat: Double = 40.4168, _ lon: Double = -3.7038) -> GPSHistoryFix {
        GPSHistoryFix(date: Date(timeIntervalSince1970: seconds), latitude: lat, longitude: lon)
    }
    func testSignalLossSeparatesTracks() {
        XCTAssertEqual(GPSRouteSegments.split([fix(0),fix(60),fix(500),fix(560)]).map(\.count), [2,2])
    }
    func testImpossibleJumpIsNotConnected() {
        XCTAssertTrue(GPSRouteSegments.split([fix(0),fix(1,48.8566,2.3522)]).isEmpty)
    }
    func testPlaybackUnavailableDuringOutage() {
        let positions = [fix(0),fix(60),fix(500),fix(560)]
        XCTAssertNil(GPSPlaybackPosition.at(Date(timeIntervalSince1970:300), in:positions).coordinates)
        XCTAssertNotNil(GPSPlaybackPosition.at(Date(timeIntervalSince1970:30), in:positions).coordinates)
    }
    func testExactFixIsObserved() {
        switch GPSPlaybackPosition.at(Date(timeIntervalSince1970:60), in:[fix(0),fix(60)]) {
        case .observed: break
        default: XCTFail("The sample must be observed")
        }
    }
    func testNoPositionOutsideRecordedBounds() {
        let positions = [fix(0),fix(60)]
        XCTAssertNil(GPSPlaybackPosition.at(Date(timeIntervalSince1970: -1), in:positions).coordinates)
        XCTAssertNil(GPSPlaybackPosition.at(Date(timeIntervalSince1970:61), in:positions).coordinates)
    }
}
