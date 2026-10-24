import XCTest
@testable import MiMapaDelTiempo

final class GridAverageEngineTests: XCTestCase {
    let a = Cell(row: 140000, column: 200000)
    let b = Cell(row: 140000, column: 200001)

    private func interval(_ start: Double, _ end: Double, _ cell: Cell) -> AssignedInterval {
        AssignedInterval(start: Date(timeIntervalSince1970: start),
                         end: Date(timeIntervalSince1970: end),
                         cell: cell, quality: "observado", source: "gps")
    }

    func testTotalDividedByActualReturnsAndGlobalWeightedAverage() {
        let data = [interval(10, 70, a), interval(70, 80, b),
                    interval(80, 200, a), interval(200, 230, b)]
        let s = GridAverageEngine.calculate(data)
        XCTAssertEqual(s.byID[a.id]?.visits, 2)
        XCTAssertEqual(s.byID[a.id]?.seconds, 180)
        XCTAssertEqual(s.byID[a.id]?.average, 90)
        XCTAssertEqual(s.byID[b.id]?.visits, 2)
        XCTAssertEqual(s.byID[b.id]?.average, 20)
        XCTAssertEqual(s.totalVisits, 4)
        XCTAssertEqual(s.globalAverage, 55)
    }

    func testFragmentedSameCellAndGapRemainOneVisit() {
        let data = [interval(10, 20, a), interval(40, 70, a),
                    interval(80, 90, a)]
        let stat = GridAverageEngine.calculate(data).byID[a.id]
        XCTAssertEqual(stat?.visits, 1)
        XCTAssertEqual(stat?.seconds, 50)
        XCTAssertNil(stat?.variation)
    }

    func testConsistencyUsesVariationNotOnlyTheAverage() {
        let equal = [interval(0, 60, a), interval(60, 70, b),
                     interval(70, 130, a), interval(130, 140, b),
                     interval(140, 200, a)]
        let s = GridAverageEngine.calculate(equal)
        XCTAssertEqual(s.byID[a.id]?.variation ?? -1, 0, accuracy: 0.00001)
        XCTAssertEqual(s.stable, 1)
        XCTAssertNil(s.byID[b.id]?.variation)

        let uneven = [interval(0, 10, a), interval(10, 20, b),
                      interval(20, 30, a), interval(30, 40, b),
                      interval(40, 300, a)]
        XCTAssertGreaterThan(GridAverageEngine.calculate(uneven).byID[a.id]?.variation ?? 0, 0.75)
    }

    func testPeriodClipsVisitWithoutCreatingExtraEntrance() {
        let now = Date(timeIntervalSince1970: 200000)
        let dayStart = Calendar.current.startOfDay(for: now)
        let data = [
            AssignedInterval(start: dayStart.addingTimeInterval(-50),
                             end: dayStart.addingTimeInterval(50),
                             cell: a, quality:"observado",source:"gps"),
            AssignedInterval(start: dayStart.addingTimeInterval(50),
                             end: dayStart.addingTimeInterval(70),
                             cell: b, quality:"observado",source:"gps")
        ]
        let stat = GridAverageEngine.calculate(data, period: .today, now: now).byID[a.id]
        XCTAssertEqual(stat?.seconds, 50)
        XCTAssertEqual(stat?.visits, 1)
    }

    func testReadOnlyAndEmptyHistory() {
        let data = [interval(10, 20, a)]
        let original = data.map(\.id)
        _ = GridAverageEngine.calculate(data)
        XCTAssertEqual(data.map(\.id), original)
        XCTAssertEqual(GridAverageEngine.calculate([]).totalVisits, 0)
        XCTAssertEqual(GridAverageEngine.calculate([]).globalAverage, 0)
    }
}
