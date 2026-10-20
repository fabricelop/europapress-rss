import XCTest
import Foundation
@testable import MiMapaDelTiempo

final class TimeMapPeriodPolicyTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func moment(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 10,
                                              day: day, hour: hour, minute: minute))!
    }

    func testStayCrossingMidnightOnlyShowsTodayPortion() {
        let now = moment(20, 0, 45)
        let stay: TimeInterval = 105 * 60 // Desde las 23:00 de ayer.
        XCTAssertEqual(TimeMapPeriodPolicy.clippedStay(stay, period: .all,
                                                        now: now, calendar: utcCalendar), stay)
        XCTAssertEqual(TimeMapPeriodPolicy.clippedStay(stay, period: .today,
                                                        now: now, calendar: utcCalendar), 45 * 60)
        XCTAssertEqual(TimeMapPeriodPolicy.clippedStay(stay, period: .week,
                                                        now: now, calendar: utcCalendar), stay)
    }

    func testWeekIsRollingAndMonthAndYearUseCalendarBoundaries() {
        let now = moment(20, 9, 0)
        let longStay: TimeInterval = 40 * 86_400
        XCTAssertEqual(TimeMapPeriodPolicy.clippedStay(longStay, period: .week,
                                                        now: now, calendar: utcCalendar),
                       7 * 86_400)
        XCTAssertEqual(TimeMapPeriodPolicy.clippedStay(longStay, period: .month,
                                                        now: now, calendar: utcCalendar),
                       now.timeIntervalSince(utcCalendar.date(from:
                           DateComponents(year:2026,month:10,day:1))!))
        XCTAssertEqual(TimeMapPeriodPolicy.clippedStay(longStay, period: .year,
                                                        now: now, calendar: utcCalendar),
                       longStay)
    }

    func testMidnightInvalidatesCachedPeriodsEvenWithoutGPSFixes() {
        let before = moment(19, 23, 59)
        let after = moment(20, 0, 1)
        for period in [TimePeriod.today, .month, .year] {
            XCTAssertNotEqual(TimeMapPeriodPolicy.refreshBucket(for: period,
                         now: before, calendar: utcCalendar),
                              TimeMapPeriodPolicy.refreshBucket(for: period,
                         now: after, calendar: utcCalendar))
        }
        XCTAssertEqual(TimeMapPeriodPolicy.refreshBucket(for: .all,
                         now: before, calendar: utcCalendar),
                       TimeMapPeriodPolicy.refreshBucket(for: .all,
                         now: after, calendar: utcCalendar))
    }

    func testRollingWeekAndInvalidDurations() {
        let first = moment(20, 9, 0)
        XCTAssertNotEqual(TimeMapPeriodPolicy.refreshBucket(for: .week,now:first,
                                                             calendar:utcCalendar),
                          TimeMapPeriodPolicy.refreshBucket(for: .week,
                                now:first.addingTimeInterval(65),calendar:utcCalendar))
        XCTAssertEqual(TimeMapPeriodPolicy.clippedStay(-100,period:.today,now:first),0)
        XCTAssertEqual(TimeMapPeriodPolicy.clippedStay(.infinity,period:.all,now:first),0)
    }
}
