import XCTest
@testable import MiMapaDelTiempo

final class SiteAtlasEngineTests: XCTestCase {
    private var calendar:Calendar {
        var c=Calendar(identifier:.gregorian)
        c.timeZone=TimeZone(identifier:"Europe/Madrid")!
        return c
    }

    private func date(_ day:Int,_ hour:Int,_ minute:Int)->Date {
        calendar.date(from:DateComponents(year:2026,month:10,day:day,
                                          hour:hour,minute:minute))!
    }

    private func visit(_ site:IdentifiedSite,_ intervals:[AssignedInterval],
                       confirmed:Bool)->SiteVisitRecord {
        let stay=SiteGridStay(cell:Cell(row:11,column:22),
            start:intervals.first!.start,end:intervals.last!.end,
            confirmedSeconds:intervals.reduce(0){$0+$1.seconds},
            fragments:intervals)
        return SiteVisitRecord(id:UUID().uuidString,stay:stay,
            from:stay.start,to:stay.end,
            gpsSeconds:stay.confirmedSeconds,confirmed:confirmed)
    }

    func testMidnightSplitNeverInventsMissingGPSSeconds() {
        let site=IdentifiedSite(name:"Casa",latitude:40,longitude:-3,origin:"private")
        let cell=Cell(row:11,column:22)
        let intervals=[
            AssignedInterval(start:date(28,23,30),end:date(28,23,50),
                             cell:cell,quality:"observado",source:"gps"),
            AssignedInterval(start:date(29,0,10),end:date(29,0,40),
                             cell:cell,quality:"observado",source:"gps")
        ]
        let record=visit(site,intervals,confirmed:false)
        let out=SiteAtlasEngine.build(visits:[site.id:[record]],
                                      sites:[site],calendar:calendar)
        XCTAssertEqual(out.days.count,2)
        XCTAssertEqual(out.days[0].seconds,1800,accuracy:0.01)
        XCTAssertEqual(out.days[1].seconds,1200,accuracy:0.01)
        XCTAssertEqual(out.days.flatMap(\.places)
            .reduce(0){$0+$1.seconds},3000,accuracy:0.01)
        XCTAssertEqual(out.days.flatMap(\.places)
            .reduce(0){$0+$1.verifiedSeconds},0)
    }

    func testRankingCombinesDaysWithoutCombiningSiteIdentities() {
        let a=IdentifiedSite(name:"SAP",latitude:40,longitude:-3,origin:"private")
        let b=IdentifiedSite(name:"Casa",latitude:40.1,longitude:-3,origin:"private")
        let cell=Cell(row:11,column:22)
        func interval(_ start:Date,_ seconds:Double)->AssignedInterval {
            AssignedInterval(start:start,end:start.addingTimeInterval(seconds),
                             cell:cell,quality:"observado",source:"gps")
        }
        let records:[UUID:[SiteVisitRecord]]=[
            a.id:[visit(a,[interval(date(28,8,0),3600)],confirmed:true),
                  visit(a,[interval(date(29,8,0),3600)],confirmed:false)],
            b.id:[visit(b,[interval(date(28,9,0),5400)],confirmed:true)]
        ]
        let out=SiteAtlasEngine.build(visits:records,sites:[a,b],
                                      calendar:calendar)
        let rank=SiteAtlasEngine.rank(out.days)
        XCTAssertEqual(rank.count,2)
        XCTAssertEqual(rank[0].siteID,a.id)
        XCTAssertEqual(rank[0].seconds,7200,accuracy:0.01)
        XCTAssertEqual(rank[0].verifiedSeconds,3600,accuracy:0.01)
        XCTAssertEqual(rank[1].siteID,b.id)
        XCTAssertEqual(out.globalColorIndexes.count,2)
    }

    func testAutumnTimeChangeUsesCalendarDateNotFixed24HourBoundary() {
        let home=IdentifiedSite(name:"Casa",latitude:40,longitude:-3,origin:"private")
        let a=date(25,0,30),b=date(25,3,30)
        let fragment=AssignedInterval(start:a,end:b,
            cell:Cell(row:11,column:22),quality:"observado",source:"gps")
        let out=SiteAtlasEngine.build(visits:[
            home.id:[visit(home,[fragment],confirmed:true)]],
            sites:[home],calendar:calendar)
        XCTAssertEqual(out.days.count,1)
        XCTAssertEqual(out.days[0].seconds,4*3600,accuracy:0.01)
    }
}
