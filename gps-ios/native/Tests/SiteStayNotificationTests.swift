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
}
