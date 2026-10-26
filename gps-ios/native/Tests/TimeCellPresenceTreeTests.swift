import XCTest
@testable import MiMapaDelTiempo

final class TimeCellPresenceTreeTests: XCTestCase {
    private let cell = Cell(row: 100, column: 500)
    private var madrid: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        madrid.date(from: DateComponents(year:y,month:m,day:d,hour:h,minute:min))!
    }

    private func visit(_ from: Date, _ to: Date) -> TimeVisit {
        let piece = AssignedInterval(start: from, end: to, cell: cell,
                                     quality: "observado", source: "gps")
        return TimeVisit(id: String(from.timeIntervalSince1970),
                         start: from, end: to,
                         confirmedSeconds: to.timeIntervalSince(from),
                         fragments: [piece], mergedSessions: 1,
                         hasTrackingPause: false)
    }

    func testOnlyActuallyVisitedYearsMonthsAndDaysAreListed() {
        let a=visit(date(2026,10,11,10), date(2026,10,11,11))
        let b=visit(date(2026,10,25,23,50), date(2026,10,26,0,10))
        let c=visit(date(2026,12,3,16), date(2026,12,3,17))
        let invisible=visit(date(2026,10,20,12), date(2026,10,20,12).addingTimeInterval(0.4))
        let result=CellPresenceIndex.build([a,b,c,invisible],total:8_400.4,calendar:madrid)
        XCTAssertEqual(result.visitCount,3)
        XCTAssertEqual(result.dayCount,4)
        XCTAssertEqual(result.years.map(\.number),[2026])
        XCTAssertEqual(result.years[0].months.map(\.number),[12,10])
        let october=result.years[0].months[1]
        XCTAssertEqual(october.days.map { madrid.component(.day,from:$0.date) },[11,25,26])
        XCTAssertEqual(october.days.map(\.seconds),[3600,600,600])
        XCTAssertEqual(october.days.map(\.visits),[1,1,1])
    }

    func testYearBoundaryAndCivilDaylightSaving() {
        let d1=visit(date(2026,12,31,23,45),date(2027,1,1,0,15))
        let d2=visit(date(2026,10,25,1,30),date(2026,10,25,3,30))
        let result=CellPresenceIndex.build([d1,d2],total: d1.confirmedSeconds+d2.confirmedSeconds,
                                           calendar:madrid)
        XCTAssertEqual(result.years.map(\.number),[2027,2026])
        XCTAssertEqual(result.years[0].months[0].days.count,1)
        XCTAssertEqual(result.years[0].months[0].days[0].seconds,900)
        let months=result.years[1].months
        XCTAssertEqual(months.map(\.number),[12,10])
        XCTAssertEqual(months[0].days[0].seconds,900)
        XCTAssertEqual(months[1].days[0].seconds,d2.confirmedSeconds,accuracy:0.001)
    }

    func testNoGpsFragmentMeansNoPresenceDay() {
        let start=date(2026,10,11,23,55)
        let end=date(2026,10,12,0,5)
        // A visit spanning midnight but with recorded GPS only before it:
        // the next calendar day must NOT be listed as visited.
        let piece=AssignedInterval(start:start,end:date(2026,10,12,0),
                                   cell:cell,quality:"observado",source:"gps")
        let v=TimeVisit(id:"gap",start:start,end:end,confirmedSeconds:300,
                        fragments:[piece],mergedSessions:1,hasTrackingPause:false)
        let result=CellPresenceIndex.build([v],total:300,calendar:madrid)
        XCTAssertEqual(result.dayCount,1)
        XCTAssertEqual(result.years[0].months[0].days.count,1)
        XCTAssertEqual(madrid.component(.day,from:result.years[0].months[0].days[0].date),11)
    }
}
