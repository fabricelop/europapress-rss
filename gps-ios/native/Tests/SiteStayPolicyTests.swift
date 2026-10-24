import XCTest
@testable import MiMapaDelTiempo

final class SiteStayPolicyTests: XCTestCase {
    private let square = "140:45"
    private let a = IdentifiedSite(name: "Cafetería", latitude: 40, longitude: -3, origin: "apple")
    private let b = IdentifiedSite(name: "Tienda", latitude: 40, longitude: -3, origin: "apple")
    private func choose(_ place: IdentifiedSite, _ time: Double,
                        _ votes: [SiteStayAssignment]) -> [SiteStayAssignment] {
        SiteStayPolicy.select(siteID: place.id, cellID: square,
                              entered: Date(timeIntervalSince1970: time),
                              assignments: votes)
    }

    func testFirstStayNeedsOneOptionalConfirmation() {
        let time = Date(timeIntervalSince1970: 1200)
        XCTAssertEqual(SiteStayPolicy.decision(cellID: square, entered: time, elapsed: 899,
                         thresholdMinutes: 15, sites: [a], assignments: [],
                         dismissedKeys: []), .tooEarly)
        XCTAssertEqual(SiteStayPolicy.decision(cellID: square, entered: time, elapsed: 901,
                         thresholdMinutes: 15, sites: [a], assignments: [],
                         dismissedKeys: []), .needsConfirmation)
        XCTAssertNil(SiteStayPolicy.automaticChoice(cellID: square, entered: time, elapsed: 901,
                         thresholdMinutes: 15, sites: [a], assignments: [], dismissedKeys: []))
    }

    func testMostFrequentlyConfirmedSiteWinsRegardlessOfAutomaticVotes() {
        var votes: [SiteStayAssignment] = []
        votes = choose(a, 1, votes)
        votes = choose(b, 2, votes)
        votes = choose(a, 3, votes)
        // Nine previous automatic guesses of B must NOT overturn confirmations.
        for second in 10...18 {
            votes.append(SiteStayAssignment(id: SiteStayPolicy.visitKey(cellID:square,
                         entered:Date(timeIntervalSince1970:Double(second))),
                         cellID:square,startedAt:Date(timeIntervalSince1970:Double(second)),
                         siteID:b.id,confirmed:false))
        }
        let keyTime = Date(timeIntervalSince1970: 300)
        XCTAssertEqual(SiteStayPolicy.automaticChoice(cellID:square,entered:keyTime,
                         elapsed:1000,thresholdMinutes:15,sites:[a,b],
                         assignments:votes,dismissedKeys:[]), a.id)
        XCTAssertEqual(SiteStayPolicy.rankedSiteIDs(votes, cellID:square,
                         validIDs:Set([a.id,b.id])),[a.id,b.id])
    }

    func testOneTapCorrectionIsPersistableAndDoesNotDoubleCountVisit() {
        let t = Date(timeIntervalSince1970: 1700)
        let old = SiteStayAssignment(id:SiteStayPolicy.visitKey(cellID:square,entered:t),
                                    cellID:square,startedAt:t,siteID:a.id,confirmed:false)
        let changed = SiteStayPolicy.select(siteID:b.id,cellID:square,entered:t,
                                             assignments:[old])
        XCTAssertEqual(changed.count,1)
        XCTAssertEqual(changed[0].siteID,b.id)
        XCTAssertTrue(changed[0].confirmed)
        XCTAssertEqual(SiteStayPolicy.confirmedCounts(changed,cellID:square)[b.id],1)
    }

    func testSkipSuppressesOnlyThisStay() {
        let t = Date(timeIntervalSince1970: 2000)
        let skipped = Set([SiteStayPolicy.visitKey(cellID:square,entered:t)])
        XCTAssertEqual(SiteStayPolicy.decision(cellID:square,entered:t,elapsed:1500,
                         thresholdMinutes:15,sites:[a],assignments:[],
                         dismissedKeys:skipped),.skipped)
        XCTAssertEqual(SiteStayPolicy.decision(cellID:square,entered:
                         Date(timeIntervalSince1970:3000),elapsed:1500,
                         thresholdMinutes:15,sites:[a],assignments:[],
                         dismissedKeys:skipped),.needsConfirmation)
    }

    func testOldAndOtherCellsVotesAreIsolated() {
        let votes = choose(a, 200, [])
        XCTAssertNil(SiteStayPolicy.automaticChoice(cellID:"other",
                    entered:Date(timeIntervalSince1970:300),elapsed:1500,
                    thresholdMinutes:15,sites:[a],assignments:votes,dismissedKeys:[]))
        XCTAssertNil(SiteStayPolicy.automaticChoice(cellID:square,
                    entered:Date(timeIntervalSince1970:200),elapsed:1500,
                    thresholdMinutes:15,sites:[a],assignments:votes,dismissedKeys:[]))
    }
}
