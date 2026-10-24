import XCTest
@testable import MiMapaDelTiempo

final class SiteVisitLookupTests: XCTestCase {
    private let a=Cell(row:100,column:500)
    private let b=Cell(row:100,column:501)
    private func interval(_ from:Double,_ to:Double,_ cell:Cell)->AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:from),
                         end:Date(timeIntervalSince1970:to),
                         cell:cell,quality:"observado",source:"gps")
    }
    private func site(_ name:String)->IdentifiedSite {
        IdentifiedSite(name:name,latitude:40.4,longitude:-3.6,origin:"private")
    }
    func testMultiSiteSubperiodsPreserveExactGPSSeconds() {
        let cafe=site("Café"), park=site("Parque")
        let raw=[interval(0,1800,a)]
        let stay=SiteStayHistory.extract(raw)[0]
        let parts=[
            SiteStayPart(stayID:stay.id,from:stay.start,
               to:Date(timeIntervalSince1970:600),kind:.place,siteID:cafe.id,confirmed:true),
            SiteStayPart(stayID:stay.id,from:Date(timeIntervalSince1970:600),
               to:stay.end,kind:.place,siteID:park.id,confirmed:false)
        ]
        let result=SiteVisitLookup.index(intervals:raw,parts:parts,
                                         assignments:[],sites:[cafe,park])
        XCTAssertEqual(result[cafe.id]?.count,1)
        XCTAssertEqual(result[park.id]?.count,1)
        XCTAssertEqual(result[cafe.id]?[0].gpsSeconds,600)
        XCTAssertEqual(result[park.id]?[0].gpsSeconds,1200)
        XCTAssertEqual(result[cafe.id]?[0].confirmed,true)
        XCTAssertEqual(result[park.id]?[0].confirmed,false)
    }
    func testConfirmedLegacyStayAppearsWithoutManualParts() {
        let park=site("Parque")
        let raw=[interval(1000,1600,a)]
        let stay=SiteStayHistory.extract(raw)[0]
        let legacy=SiteStayAssignment(id:stay.id,cellID:a.id,startedAt:stay.start,
                                      siteID:park.id,confirmed:true)
        let result=SiteVisitLookup.index(intervals:raw,parts:[],
                            assignments:[legacy],sites:[park])
        XCTAssertEqual(result[park.id]?.count,1)
        XCTAssertEqual(result[park.id]?[0].gpsSeconds,600)
        XCTAssertEqual(result[park.id]?[0].confirmed,true)
    }
    func testAutomaticFromOtherSquareNeverBecomesAVisit() {
        let park=site("Parque")
        let raw=[interval(1000,1600,a),interval(1700,2400,b)]
        let first=SiteStayHistory.extract(raw).first(where:{$0.cell==a})!
        let legacy=SiteStayAssignment(id:first.id,cellID:a.id,
                                      startedAt:first.start,siteID:park.id,
                                      confirmed:true)
        let result=SiteVisitLookup.index(intervals:raw,parts:[],
                                         assignments:[legacy],sites:[park])
        XCTAssertEqual(result[park.id]?.count,1)
        XCTAssertEqual(result[park.id]?[0].cell,a)
    }
    func testUnassignedPassingOrDeletedSiteIsNotShown() {
        let removed=site("Borrado")
        let raw=[interval(100,900,a)]
        let stay=SiteStayHistory.extract(raw)[0]
        let unassigned=SiteStayPart(stayID:stay.id,from:stay.start,to:stay.end,
                                    kind:.unassigned,siteID:nil)
        let result=SiteVisitLookup.index(intervals:raw,parts:[unassigned],
                                         assignments:[],sites:[removed])
        XCTAssertTrue(result.isEmpty)
    }
    func testAccentInsensitiveSearch() {
        let park=site("Parque de la Constitución")
        XCTAssertEqual(SiteVisitLookup.search([park],text:"CONSTITUCION").count,1)
        XCTAssertTrue(SiteVisitLookup.search([park],text:"polideportivo").isEmpty)
    }
}
