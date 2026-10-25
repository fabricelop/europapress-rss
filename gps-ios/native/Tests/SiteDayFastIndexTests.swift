import XCTest
@testable import MiMapaDelTiempo

final class SiteDayFastIndexTests:XCTestCase {
    private var calendar:Calendar {
        var c=Calendar(identifier:.gregorian)
        c.timeZone=TimeZone(identifier:"Europe/Madrid")!
        return c
    }
    private func date(_ year:Int,_ month:Int,_ day:Int,_ hour:Int) -> Date {
        calendar.date(from:DateComponents(year:year,month:month,day:day,hour:hour))!
    }
    private let cell=Cell(row:100,column:500)
    private func stay(_ start:Date,_ end:Date)->SiteGridStay {
        let fragment=AssignedInterval(start:start,end:end,cell:cell,
                                      quality:"observado",source:"gps")
        return SiteGridStay(cell:cell,start:start,end:end,
                            confirmedSeconds:end.timeIntervalSince(start),
                            fragments:[fragment])
    }
    func testIndexedDayOnlyReturnsMatchingStaysIncludingMidnight() {
        let s=stay(date(2026,10,24,23),date(2026,10,25,1))
        let indexed=SiteDayIndex.build([s],calendar:calendar)
        XCTAssertEqual(indexed[calendar.startOfDay(for:s.start)]?.count,1)
        XCTAssertEqual(indexed[calendar.startOfDay(for:s.end)]?.count,1)
        XCTAssertEqual(indexed.count,2)
    }
    func testHistoricalConfirmedVoteOnlyProposesWithinExactSquare() {
        let a=IdentifiedSite(name:"Un sitio",latitude:40,longitude:-3,origin:"private")
        let from=date(2026,10,21,9)
        let s=stay(from,from.addingTimeInterval(900))
        let assignment=SiteStayAssignment(id:s.id,cellID:cell.id,
                      startedAt:from,siteID:a.id,confirmed:true)
        let lookup=SiteDayPartsIndex(assignments:[assignment],
                                   parts:[],sites:[a])
        XCTAssertEqual(lookup.parts(for:s).first?.siteID,a.id)
        let different=Cell(row:100,column:501)
        let other=SiteGridStay(cell:different,start:from,end:s.end,
                                confirmedSeconds:900,fragments:[])
        XCTAssertNil(lookup.parts(for:other).first?.siteID)
    }
    func testExplicitSplitOverridesLegacyAndPreservesTwoPlaces() {
        let first=UUID(),second=UUID()
        let from=date(2026,10,21,9)
        let s=stay(from,from.addingTimeInterval(900))
        let parts=[
            SiteStayPart(stayID:s.id,from:from,to:from.addingTimeInterval(500),
                kind:.place,siteID:first,confirmed:true),
            SiteStayPart(stayID:s.id,from:from.addingTimeInterval(500),
                to:s.end,kind:.place,siteID:second,confirmed:true)
        ]
        let lookup=SiteDayPartsIndex(assignments:[],parts:parts,sites:[
            IdentifiedSite(id:first,name:"Primero",latitude:40,longitude:-3,origin:"private"),
            IdentifiedSite(id:second,name:"Segundo",latitude:40,longitude:-3,origin:"private")])
        XCTAssertEqual(lookup.parts(for:s),parts)
    }
    func testAutumnClockChangeUsesCivilDates() {
        let start=date(2026,10,24,23)
        let finish=date(2026,10,26,1)
        let grouped=SiteDayIndex.build([stay(start,finish)],calendar:calendar)
        XCTAssertEqual(grouped.count,3)
    }
}
