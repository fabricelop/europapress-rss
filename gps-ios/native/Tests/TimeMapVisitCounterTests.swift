import XCTest
@testable import MiMapaDelTiempo

final class TimeMapVisitCounterTests: XCTestCase {
    private let a = Cell(row: 40, column: 10)
    private let b = Cell(row: 40, column: 11)
    private let c = Cell(row: 40, column: 12)
    private func interval(_ start: Double, _ end: Double, _ cell: Cell) -> AssignedInterval {
        AssignedInterval(start: Date(timeIntervalSince1970: start),
                         end: Date(timeIntervalSince1970: end),
                         cell: cell, quality: "observado", source: "gps")
    }

    func testReturnToSameGridCountsAnotherVisit() {
        let intervals = [interval(10, 50, a), interval(50, 70, b),
                         interval(70, 120, a)]
        let result = TimeMapVisitCounter.historical(intervals, cellIDs: [a.id])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.lastInside)
        XCTAssertEqual(TimeMapVisitCounter.historical(intervals, cellIDs: [b.id]).count, 1)
    }

    func testMovingInsideOneZoneDoesNotCountAnotherVisit() {
        let intervals = [interval(10, 50, a), interval(50, 70, b),
                         interval(70, 90, c), interval(90, 120, b)]
        let result = TimeMapVisitCounter.historical(intervals,
                                                     cellIDs: [a.id, b.id])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.lastInside)
    }

    func testContinuousStayAndMissingGPSDoNotMultiplyVisits() {
        let intervals = [interval(10, 30, a), interval(80, 110, a),
                         interval(130, 180, a)]
        XCTAssertEqual(TimeMapVisitCounter.historical(intervals,
                        cellIDs: [a.id]).count, 1)
    }

    func testWindowExcludesOldVisitButIncludesOverlappingVisit() {
        let intervals = [interval(10, 30, a), interval(30, 50, b),
                         interval(50, 100, a)]
        let window = DateInterval(start: Date(timeIntervalSince1970: 70),
                                  end: Date(timeIntervalSince1970: 90))
        XCTAssertEqual(TimeMapVisitCounter.historical(intervals,
                        cellIDs: [a.id], window: window).count, 1)
    }

    func testCurrentUnpersistedEntranceAppearsOnce() {
        let previous = TimeMapVisitCounter.historical(
            [interval(10, 30, a), interval(30, 60, b)], cellIDs: [a.id])
        XCTAssertEqual(TimeMapVisitCounter.includingCurrent(previous,
                        currentCellID: a.id, cellIDs: [a.id]), 2)
        let alreadyInside = TimeMapVisitCounter.historical(
            [interval(10, 60, a)], cellIDs: [a.id])
        XCTAssertEqual(TimeMapVisitCounter.includingCurrent(alreadyInside,
                        currentCellID: a.id, cellIDs: [a.id]), 1)
    }
}
