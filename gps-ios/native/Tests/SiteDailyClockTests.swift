import XCTest
@testable import MiMapaDelTiempo

final class SiteDailyClockTests: XCTestCase {
    let a=Cell(row:100,column:500)
    private var cal:Calendar {
        var c=Calendar(identifier:.gregorian)
        c.timeZone=TimeZone(identifier:"Europe/Madrid")!
        return c
    }
    func sample(_ from:Date,_ to:Date)->AssignedInterval {
        AssignedInterval(start:from,end:to,cell:a,quality:"observado",source:"gps")
    }
    func date(_ y:Int,_ m:Int,_ d:Int,_ h:Int,_ minute:Int=0)->Date {
        cal.date(from:DateComponents(year:y,month:m,day:d,hour:h,minute:minute))!
    }
    func testTwoDifferentPlacesInsideSingleGridAreBothVisible() {
        let from=date(2026,10,24,10), end=date(2026,10,24,11)
        let stay=SiteStayHistory.extract([sample(from,end)])[0]
        let first=UUID(),second=UUID()
        let parts=[
            SiteStayPart(stayID:stay.id,from:from,to:from.addingTimeInterval(1200),
                kind:.place,siteID:first,confirmed:true),
            SiteStayPart(stayID:stay.id,from:from.addingTimeInterval(1200),
                to:end,kind:.place,siteID:second,confirmed:false)
        ]
        let results=SiteDailyClock.segments(stays:[stay],partsByStay:[stay.id:parts],
                          on:from,calendar:cal)
        XCTAssertEqual(results.count,2)
        XCTAssertEqual(results.map(\.seconds).reduce(0,+),3600)
        XCTAssertEqual(SiteDailyClock.totalsBySite(results)[first],1200)
        XCTAssertEqual(SiteDailyClock.totalsBySite(results)[second],2400)
        XCTAssertTrue(results[0].manuallyConfirmed)
        XCTAssertFalse(results[1].manuallyConfirmed)
    }
    func testGapBetweenRealGPSFragmentsStaysUncolored() {
        let from=date(2026,10,24,10)
        let raw=[sample(from,from.addingTimeInterval(250)),
                 sample(from.addingTimeInterval(320),from.addingTimeInterval(600))]
        let stay=SiteStayHistory.extract(raw)[0]
        let results=SiteDailyClock.segments(stays:[stay],partsByStay:[:],
                          on:from,calendar:cal)
        XCTAssertEqual(results.count,2)
        XCTAssertEqual(results.map(\.seconds).reduce(0,+),530)
        XCTAssertEqual(results[0].kind,.unassigned)
    }
    func testCrossMidnightClipsAtCivilDayBounds() {
        let start=date(2026,10,24,23,55)
        let end=date(2026,10,25,0,10)
        let stay=SiteStayHistory.extract([sample(start,end)])[0]
        let saturday=SiteDailyClock.segments(stays:[stay],partsByStay:[:],
                       on:start,calendar:cal)
        let sunday=SiteDailyClock.segments(stays:[stay],partsByStay:[:],
                       on:end,calendar:cal)
        XCTAssertEqual(saturday.map(\.seconds).reduce(0,+),300)
        XCTAssertEqual(sunday.map(\.seconds).reduce(0,+),600)
    }
    func testAutumnDSTDayHasFourProperCivilHourBands() {
        let day=date(2026,10,25,10)
        let bands=SiteDailyClock.bands([],day:day,calendar:cal)
        XCTAssertEqual(bands.count,4)
        XCTAssertEqual(bands.map(\.label),["00:00","06:00","12:00","18:00"])
        XCTAssertEqual(bands.map(\.endLabel),["06:00","12:00","18:00","24:00"])
        XCTAssertEqual(bands.map{$0.to.timeIntervalSince($0.from)}.reduce(0,+),90000)
    }
    func testPassingIsDistinctAndProposalsNotConfirmed() {
        let from=date(2026,10,24,10), to=from.addingTimeInterval(600)
        let stay=SiteStayHistory.extract([sample(from,to)])[0]
        let parts=[SiteStayPart(stayID:stay.id,from:from,to:to,
                                kind:.passing,siteID:nil)]
        let result=SiteDailyClock.segments(stays:[stay],
                      partsByStay:[stay.id:parts],on:from,calendar:cal)
        XCTAssertEqual(result.count,1)
        XCTAssertEqual(result[0].kind,.passing)
        XCTAssertNil(result[0].siteID)
    }
}
