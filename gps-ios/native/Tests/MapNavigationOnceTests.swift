import XCTest
@testable import MiMapaDelTiempo

final class MapNavigationOnceTests: XCTestCase {
    func testStatisticsSelectionIsConsumedExactlyOnce() {
        var request=MapNavigationOnce()
        let cell=Cell(row:145257,column:149248)
        request.enqueue(cell)
        XCTAssertEqual(request.consume(),cell)
        XCTAssertNil(request.consume()) // Tab change cannot replay the old location
    }

    func testNewRequestOverridesPendingAndAllowsSameCellAgain() {
        var request=MapNavigationOnce()
        let first=Cell(row:1,column:2)
        let second=Cell(row:3,column:4)
        request.enqueue(first)
        request.enqueue(second)
        XCTAssertEqual(request.consume(),second)
        request.enqueue(second)
        XCTAssertEqual(request.consume(),second)
        XCTAssertNil(request.consume())
    }
}
