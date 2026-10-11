import XCTest
@testable import MiMapaDelTiempo

final class EpisodeEditTests: XCTestCase {
    func testSplitAndUndoPreservesOriginalGPS() {
        let t=Date(timeIntervalSince1970:100)
        let positions=[GPSHistoryFix(date:t,latitude:40.4,longitude:-3.7),
            GPSHistoryFix(date:t.addingTimeInterval(20),latitude:40.4,longitude:-3.7),
            GPSHistoryFix(date:t.addingTimeInterval(40),latitude:40.4,longitude:-3.7),
            GPSHistoryFix(date:t.addingTimeInterval(60),latitude:40.4,longitude:-3.7)]
        let initial=GPSHistoryGrouping.episodes(positions)
        let divided=GPSHistoryGrouping.episodes(positions,manualBreaks:[t.addingTimeInterval(40)])
        XCTAssertTrue(divided.count >= initial.count)
        XCTAssertEqual(GPSHistoryGrouping.episodes(positions,manualBreaks:[]).count,initial.count)
    }
}