import XCTest
@testable import MiMapaDelTiempo

final class BioGridNeighborhoodTests:XCTestCase {
    func testEightNeighborsAreUniqueAndCorrectlyOriented() {
        let center=Grid.cell(latitude:40.4168,longitude:-3.7038)
        let current=Grid.center(center)
        let places=(0..<8).map { BioGridNeighborhood.cell(near:center,direction:$0) }
        XCTAssertEqual(Set(places.map(\.id)).count,8)
        XCTAssertFalse(places.contains(center))
        for index in [0,4,5] { XCTAssertGreaterThan(Grid.center(places[index]).latitude,current.latitude) }
        for index in [1,6,7] { XCTAssertLessThan(Grid.center(places[index]).latitude,current.latitude) }
        for index in [2,5,7] { XCTAssertGreaterThan(Grid.center(places[index]).longitude,current.longitude) }
        for index in [3,4,6] { XCTAssertLessThan(Grid.center(places[index]).longitude,current.longitude) }
        for index in 0..<4 {
            XCTAssertEqual(places[index],BioGridEngine.neighbor(center,direction:index))
        }
    }
}

final class CellSiteHistoryIndexTests:XCTestCase {
    func testOnlyChosenGridSquaresSitesAreRankedWithHistoricalDays() {
        let a=Cell(row:100,column:500),b=Cell(row:100,column:501)
        let first=IdentifiedSite(name:"Casa",latitude:40,longitude:-3,origin:"private")
        let second=IdentifiedSite(name:"Tienda",latitude:40.1,longitude:-3,origin:"private")
        func segment(_ from:Double,_ to:Double,_ cell:Cell)->AssignedInterval {
            AssignedInterval(start:Date(timeIntervalSince1970:from),
                end:Date(timeIntervalSince1970:to),cell:cell,
                quality:"observado",source:"gps")
        }
        let intervals=[segment(10000,11000,a),segment(11000,12000,b),
                       segment(12000,12800,a)]
        let stays=SiteStayHistory.extract(intervals)
        let aStays=stays.filter{$0.cell==a}.sorted{$0.start<$1.start}
        let bStay=stays.first{$0.cell==b}!
        let parts=[
            SiteStayPart(stayID:aStays[0].id,from:aStays[0].start,
                        to:aStays[0].end,kind:.place,siteID:first.id,confirmed:true),
            SiteStayPart(stayID:aStays[1].id,from:aStays[1].start,
                        to:aStays[1].end,kind:.place,siteID:second.id,confirmed:false),
            SiteStayPart(stayID:bStay.id,from:bStay.start,to:bStay.end,
                        kind:.place,siteID:first.id,confirmed:true)
        ]
        let ranking=CellSiteHistoryIndex.ranked(cell:a,intervals:intervals,
                        parts:parts,assignments:[],sites:[first,second])
        XCTAssertEqual(ranking.count,2)
        XCTAssertEqual(ranking[0].site.id,first.id)
        XCTAssertEqual(ranking[0].seconds,1000,accuracy:0.01)
        XCTAssertEqual(ranking[0].verifiedSeconds,1000,accuracy:0.01)
        XCTAssertEqual(ranking[1].site.id,second.id)
        XCTAssertEqual(ranking[1].seconds,800,accuracy:0.01)
        XCTAssertEqual(ranking[1].verifiedSeconds,0,accuracy:0.01)
        XCTAssertEqual(ranking[0].days.count,1)
        XCTAssertEqual(ranking[0].days[0].portions.count,1)
    }
    func testSiteTreeExpandsYearsThenMonthsThenChronologicalDays() {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(identifier:"Europe/Madrid")!
        func date(_ year:Int,_ month:Int,_ day:Int)->Date {
            calendar.date(from:DateComponents(year:year,month:month,day:day,
                                              hour:12))!
        }
        func day(_ year:Int,_ month:Int,_ number:Int,_ seconds:Double)->CellSiteDay {
            CellSiteDay(date:calendar.startOfDay(for:date(year,month,number)),
                        portions:[CellSiteDayPortion(
                            visit:sampleVisit(start:date(year,month,number),
                                              seconds:seconds),
                            from:date(year,month,number),
                            to:date(year,month,number).addingTimeInterval(seconds),
                            seconds:seconds)])
        }
        let rows=[
            day(2025,12,31,600),
            day(2026,1,3,900),
            day(2026,10,28,1200),
            day(2026,10,30,1800)
        ]
        let years=CellSiteHistoryIndex.years(for:rows,calendar:calendar)
        XCTAssertEqual(years.map(\.number),[2026,2025])
        XCTAssertEqual(years[0].months.map(\.number),[10,1])
        XCTAssertEqual(years[0].months[0].days.count,2)
        XCTAssertEqual(years[0].months[0].days.map(\.date),[
            calendar.startOfDay(for:date(2026,10,28)),
            calendar.startOfDay(for:date(2026,10,30))
        ])
        XCTAssertEqual(years[0].seconds,3900,accuracy:0.01)
        XCTAssertEqual(years[0].months[0].seconds,3000,accuracy:0.01)
        XCTAssertEqual(years[1].months[0].seconds,600,accuracy:0.01)
    }

    func testMidnightVisitProducesDaysInDifferentYearsWithoutInventingTime() {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(identifier:"Europe/Madrid")!
        func date(_ year:Int,_ month:Int,_ day:Int,_ hour:Int,_ minute:Int)->Date {
            calendar.date(from:DateComponents(year:year,month:month,day:day,
                                              hour:hour,minute:minute))!
        }
        let from=date(2025,12,31,23,40)
        let to=date(2026,1,1,0,30)
        let square=Cell(row:100,column:500)
        let first=AssignedInterval(start:from,end:from.addingTimeInterval(600),
                                   cell:square,quality:"observado",source:"gps")
        let second=AssignedInterval(start:to.addingTimeInterval(-900),end:to,
                                    cell:square,quality:"observado",source:"gps")
        let stay=SiteGridStay(cell:square,start:from,end:to,
            confirmedSeconds:1500,fragments:[first,second])
        let record=SiteVisitRecord(id:"split",stay:stay,from:from,
                                  to:to,gpsSeconds:1500,confirmed:true)
        let days=CellSiteHistoryIndex.days(for:[record],calendar:calendar)
        XCTAssertEqual(days.count,2)
        XCTAssertEqual(days.map(\.seconds),[900,600])
        let years=CellSiteHistoryIndex.years(for:days,calendar:calendar)
        XCTAssertEqual(years.map(\.number),[2026,2025])
        XCTAssertEqual(years.reduce(0.0){$0+$1.seconds},1500,accuracy:0.01)
    }

    private func sampleVisit(start:Date,seconds:TimeInterval)->SiteVisitRecord {
        let cell=Cell(row:100,column:500)
        let fragment=AssignedInterval(start:start,end:start.addingTimeInterval(seconds),
                                      cell:cell,quality:"observado",source:"gps")
        let stay=SiteGridStay(cell:cell,start:start,end:fragment.end,
                              confirmedSeconds:seconds,fragments:[fragment])
        return SiteVisitRecord(id:UUID().uuidString,stay:stay,
                               from:start,to:fragment.end,gpsSeconds:seconds,confirmed:true)
    }

}
