import XCTest
@testable import MiMapaDelTiempo

final class SiteCrossGridPolicyTests: XCTestCase {
    private let a=Cell(row: 137777, column: 122222)
    private var b: Cell { Cell(row:a.row+1,column:a.column) }
    private var c: Cell { Cell(row:a.row+2,column:a.column) }
    private func site(_ title:String, at cell:Cell, origin:String="apple") -> IdentifiedSite {
        let center=Grid.center(cell)
        return IdentifiedSite(name:title,latitude:center.latitude,
                              longitude:center.longitude,origin:origin)
    }
    private func assignment(_ site:IdentifiedSite, cell:Cell,
                            at time:Double) -> SiteStayAssignment {
        let moment=Date(timeIntervalSince1970:time)
        return SiteStayAssignment(id:SiteStayPolicy.visitKey(cellID:cell.id,entered:moment),
                            cellID:cell.id,startedAt:moment,siteID:site.id,confirmed:true)
    }

    func testKnownParkFromAnotherSquareIsSuggestedFirstWithoutBlindAuto() {
        let park=site("El Parque del Retiro",at:a)
        let past=[assignment(park,cell:a,at:10)]
        let options=SiteCrossGridPolicy.candidates(for:b,sites:[park],
                                            assignments:past,parts:[])
        XCTAssertEqual(options.first?.siteID,park.id)
        XCTAssertEqual(options.first?.totalConfirmations,1)
        XCTAssertNil(SiteCrossGridPolicy.safeAutomaticChoice(options))
    }

    func testSecondConfirmedSquareCanEnableUniqueNearAuto() {
        let park=site("El Parque del Retiro",at:a)
        let past=[assignment(park,cell:a,at:10),assignment(park,cell:b,at:20)]
        let options=SiteCrossGridPolicy.candidates(for:c,sites:[park],
                                            assignments:past,parts:[])
        XCTAssertEqual(options.first?.siteID,park.id)
        XCTAssertEqual(SiteCrossGridPolicy.safeAutomaticChoice(options),park.id)
    }

    func testCompetingPlacePreventsCrossSquareAuto() {
        let park=site("El Parque del Retiro",at:a)
        let shop=site("Una tienda",at:b)
        let past=[assignment(park,cell:a,at:10),
                  assignment(park,cell:b,at:20),
                  assignment(shop,cell:b,at:30)]
        let options=SiteCrossGridPolicy.candidates(for:c,sites:[park,shop],
                                            assignments:past,parts:[])
        XCTAssertNil(SiteCrossGridPolicy.safeAutomaticChoice(options))
    }

    func testExplicitLocalChoiceWinsOverNearbyOtherSquare() {
        let park=site("El Parque del Retiro",at:a)
        let shop=site("Una tienda",at:b)
        let past=[assignment(park,cell:a,at:10),assignment(park,cell:a,at:20),
                  assignment(shop,cell:b,at:30)]
        let ranked=SiteCrossGridPolicy.candidates(for:b,sites:[park,shop],
                                            assignments:past,parts:[])
        XCTAssertEqual(ranked.first?.siteID,shop.id)
    }

    func testManualMultiSiteConfirmationCountsOnlyOncePerStay() {
        let park=site("El Parque del Retiro",at:a)
        let now=Date(timeIntervalSince1970:10)
        let stay=SiteStayPolicy.visitKey(cellID:a.id,entered:now)
        let parts=[
            SiteStayPart(stayID:stay,from:now,
                         to:now.addingTimeInterval(600),kind:.place,
                         siteID:park.id,confirmed:true),
            SiteStayPart(stayID:stay,from:now.addingTimeInterval(600),
                         to:now.addingTimeInterval(1000),kind:.place,
                         siteID:park.id,confirmed:true)]
        let ranked=SiteCrossGridPolicy.candidates(for:b,sites:[park],
                                            assignments:[],parts:parts)
        XCTAssertEqual(ranked.first?.totalConfirmations,1)
    }

    func testUnconfirmedSuggestionsDoNotBecomeEvidence() {
        let park=site("El Parque del Retiro",at:a)
        let part=SiteStayPart(stayID:"\(a.id)|10",
                              from:Date(timeIntervalSince1970:10),
                              to:Date(timeIntervalSince1970:100),
                              kind:.place,siteID:park.id,confirmed:false)
        XCTAssertTrue(SiteCrossGridPolicy.candidates(for:b,sites:[park],
                        assignments:[],parts:[part]).isEmpty)
    }
}
