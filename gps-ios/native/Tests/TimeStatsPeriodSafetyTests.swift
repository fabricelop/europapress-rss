import XCTest
import Foundation
@testable import MiMapaDelTiempo

/// Regression: switching statistical date ranges only reads the canonical history.
/// The records, boundaries and daily totals must never change.
final class TimeStatsPeriodSafetyTests: XCTestCase {
    func testRepeatedPeriodSwitchesRetainAllIntervals() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let start = now.addingTimeInterval(-4 * 86_400)
        let cell = Cell(row: 402, column: -37)
        let intervals: [AssignedInterval] = (0..<3_200).map { index in
            let from = start.addingTimeInterval(Double(index) * 110)
            return AssignedInterval(start: from, end: from.addingTimeInterval(100),
                                    cell: cell, quality: "observado", source: "gps")
        }
        let rawCount = intervals.count
        let originalFirst = intervals.first!.start
        let originalLast = intervals.last!.end
        let expectedTotal = Double(rawCount) * 100

        for _ in 0..<5 {
            for period in TimePeriod.allCases {
                let range = TimeAnalytics.window(for: period, now: now, calendar: calendar)
                let totals = TimeAttribution.byCell(intervals, window: range)
                XCTAssertGreaterThanOrEqual(totals[cell.id] ?? 0, 0)
                XCTAssertLessThanOrEqual(totals[cell.id] ?? 0, expectedTotal)
            }
        }
        XCTAssertEqual(intervals.count, rawCount)
        XCTAssertEqual(intervals.first!.start, originalFirst)
        XCTAssertEqual(intervals.last!.end, originalLast)
        XCTAssertEqual(TimeAttribution.byCell(intervals)[cell.id], expectedTotal)
    }

    func testStatisticsEmptyDaysRemainSafe() {
        let now = Date()
        for period in TimePeriod.allCases {
            let range = TimeAnalytics.window(for: period, now: now)
            XCTAssertTrue(TimeAttribution.byCell([], window: range).isEmpty)
        }
    }
}
