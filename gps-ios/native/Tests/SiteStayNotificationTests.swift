import XCTest
@testable import MiMapaDelTiempo

final class SiteStayNotificationTests: XCTestCase {
    private let square = Cell(row: 100, column: 500)
    private var venue: IdentifiedSite {
        IdentifiedSite(name: "Sitio de prueba", latitude: 40.0,
                       longitude: -3.0, origin: "private")
    }

    private func stay(_ end: TimeInterval) -> SiteGridStay {
        let segment = AssignedInterval(start: Date(timeIntervalSince1970: 10_000),
            end: Date(timeIntervalSince1970: end),
            cell: square, quality: "observado", source: "gps")
        return SiteStayHistory.extract([segment])[0]
    }

    func testUnconfirmedHistoricalProposalDoesNotBecomeConfirmation() {
        let site = venue
        let record = stay(10_500)
        let first = SiteStayAssignment(
            id: SiteStayPolicy.visitKey(cellID: square.id,
                                       entered: record.start.addingTimeInterval(-5_000)),
            cellID: square.id, startedAt: record.start.addingTimeInterval(-5_000),
            siteID: site.id, confirmed: true)
        let index = SiteDayPartsIndex(assignments:[first], parts:[], sites:[site])
        let proposed = index.parts(for: record)
        XCTAssertEqual(proposed.first?.siteID, site.id)
        XCTAssertEqual(proposed.first?.confirmed, false)
    }

    func testExplicitNotificationConfirmationPersistsAsStayGrows() {
        let site = venue
        let firstStay = stay(10_500)
        let selected = SiteStayPolicy.select(siteID:site.id,
                           cellID:square.id, entered:firstStay.start, assignments:[])
        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected[0].confirmed)
        let index = SiteDayPartsIndex(assignments:selected,parts:[],sites:[site])
        XCTAssertEqual(index.parts(for:firstStay).first?.confirmed, true)
        let grown = stay(11_500)
        XCTAssertEqual(grown.id, firstStay.id)
        XCTAssertEqual(index.parts(for:grown).first?.siteID, site.id)
        XCTAssertEqual(index.parts(for:grown).first?.confirmed, true)
        XCTAssertEqual(index.parts(for:grown).first?.to, grown.end)
    }

    func testConfirmationOnlyAffectsChosenVisit() {
        let site = venue
        let first = stay(10_500)
        let next = SiteGridStay(cell:square, start:Date(timeIntervalSince1970:20_000),
                                end:Date(timeIntervalSince1970:20_600),
                                confirmedSeconds:600,fragments:[])
        let confirmed = SiteStayPolicy.select(siteID:site.id,
                       cellID:square.id,entered:first.start,assignments:[])
        let index = SiteDayPartsIndex(assignments:confirmed,parts:[],sites:[site])
        XCTAssertEqual(index.parts(for:first).first?.confirmed,true)
        XCTAssertEqual(index.parts(for:next).first?.confirmed,false)
    }
    func testHistoricalSiteGroupsNotIndividualGridSquares() {
        let b = Cell(row:100,column:501)
        let c = Cell(row:100,column:502)
        let alpha = IdentifiedSite(name:"SAP ESPAÑA",latitude:40,longitude:-3,origin:"private")
        let beta = IdentifiedSite(name:"Favorit",latitude:40.001,longitude:-3,origin:"private")
        func segment(_ start:Double,_ end:Double,_ cell:Cell)->AssignedInterval {
            AssignedInterval(start:Date(timeIntervalSince1970:start),
                             end:Date(timeIntervalSince1970:end),
                             cell:cell,quality:"observado",source:"gps")
        }
        let intervals = [
            segment(10_000,10_400,square),
            segment(10_400,10_800,b),
            segment(10_800,11_200,c),
            segment(11_200,11_600,square)
        ]
        func earlier(_ cell:Cell,_ id:UUID)->SiteStayAssignment {
            SiteStayAssignment(id:SiteStayPolicy.visitKey(
                                cellID:cell.id,entered:Date(timeIntervalSince1970:5_000)),
                               cellID:cell.id,startedAt:Date(timeIntervalSince1970:5_000),
                               siteID:id,confirmed:true)
        }
        let idx = SiteDayPartsIndex(
            assignments:[earlier(square,alpha.id),earlier(b,alpha.id),
                         earlier(c,beta.id)],
            parts:[],sites:[alpha,beta])
        let stays=SiteStayHistory.extract(intervals)
        let report=SiteDayPresentation.build(
            stays.map { SiteDaySource(stay:$0,parts:idx.parts(for:$0)) },
            on:Date(timeIntervalSince1970:10_000))
        XCTAssertEqual(report.groups.count,3)
        XCTAssertEqual(report.groups[0].entries.count,2)
        XCTAssertEqual(report.groups[0].uniqueCells,2)
        XCTAssertEqual(report.groups[0].siteID,alpha.id)
        XCTAssertEqual(report.groups[1].siteID,beta.id)
        XCTAssertEqual(report.groups[2].siteID,alpha.id)
        XCTAssertNotEqual(report.groups[0].id,report.groups[2].id)
    }
}
