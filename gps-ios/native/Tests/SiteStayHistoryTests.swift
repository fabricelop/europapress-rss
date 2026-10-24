import XCTest
@testable import MiMapaDelTiempo

final class SiteStayHistoryTests: XCTestCase {
    let a = Cell(row: 100, column: 500)
    let b = Cell(row: 100, column: 501)
    func segment(_ from: Double, _ to: Double, _ cell: Cell) -> AssignedInterval {
        AssignedInterval(start: Date(timeIntervalSince1970: from),
                         end: Date(timeIntervalSince1970: to),
                         cell: cell, quality:"observado", source:"gps")
    }
    func testOnlyContinuousStaysOverFiveMinutes() {
        let all = [segment(0, 120, a),segment(120, 480, a),
                   segment(480, 510, b),segment(700, 1100, b),
                   segment(1600, 1640, a)]
        let result = SiteStayHistory.extract(all)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.cell, b)
        XCTAssertEqual(result.last?.confirmedSeconds, 480)
    }
    func testShortGPSSamplingGapsAreNotCharged() {
        let stay = SiteStayHistory.extract([segment(100, 320, a),
                                            segment(400, 620, a)])[0]
        XCTAssertEqual(stay.elapsed, 520)
        XCTAssertEqual(stay.confirmedSeconds, 440)
        XCTAssertEqual(stay.confirmed(from:Date(timeIntervalSince1970:300),
                                       to:Date(timeIntervalSince1970:500)), 120)
    }
    func testTwoPlacesAndPassingNeverOvercountGridTime() {
        let stay = SiteStayHistory.extract([segment(0, 2700, a)])[0]
        let cafe = UUID()
        let library = UUID()
        let first = SiteStayPart(stayID:stay.id,from:stay.start,
                                to:Date(timeIntervalSince1970:900),
                                kind:.place,siteID:cafe)
        let second = SiteStayPart(stayID:stay.id,from:Date(timeIntervalSince1970:900),
                                 to:Date(timeIntervalSince1970:2100),
                                 kind:.place,siteID:library)
        let transit = SiteStayPart(stayID:stay.id,from:Date(timeIntervalSince1970:2100),
                                  to:stay.end,kind:.passing,siteID:nil)
        let parts = [first,second,transit]
        XCTAssertTrue(SiteStayHistory.valid(parts,for:stay))
        XCTAssertEqual(SiteStayHistory.assignedSeconds(parts,for:stay,siteID:cafe),900)
        XCTAssertEqual(SiteStayHistory.assignedSeconds(parts,for:stay,siteID:library),1200)
        XCTAssertEqual(parts.reduce(0){$0 + stay.confirmed(from:$1.from,to:$1.to)},2700)
    }
    func testSplitMergeAndOverlapValidation() {
        let stay = SiteStayHistory.extract([segment(0, 1800, a)])[0]
        let basic = [SiteStayHistory.defaultPart(for:stay,suggested:nil)]
        let splitted = SiteStayHistory.split(basic,partID:basic[0].id,
                              at:Date(timeIntervalSince1970:600),stay:stay)
        XCTAssertEqual(splitted?.count,2)
        XCTAssertTrue(SiteStayHistory.valid(splitted ?? [],for:stay))
        XCTAssertEqual(SiteStayHistory.mergeWithPrevious(splitted ?? [],
                        partID:splitted![1].id,stay:stay)?.count,1)
        var broken = splitted!
        broken[1].from = Date(timeIntervalSince1970:500)
        XCTAssertFalse(SiteStayHistory.valid(broken,for:stay))
    }
    func testConfirmedMultiplePlacesAreOneVotePerPlacePerStay() {
        let s = SiteStayHistory.extract([segment(0, 900, a)])[0]
        let site = UUID()
        let parts = [
            SiteStayPart(stayID:s.id,from:s.start,to:Date(timeIntervalSince1970:400),kind:.place,siteID:site,confirmed:true),
            SiteStayPart(stayID:s.id,from:Date(timeIntervalSince1970:400),to:s.end,kind:.place,siteID:site,confirmed:true)
        ]
        let votes = SiteStayHistory.confirmedSiteCounts(parts,
                         stayIDsByCell:[s.id:s.cell.id],cellID:s.cell.id)
        XCTAssertEqual(votes[site],1)
    }
}
