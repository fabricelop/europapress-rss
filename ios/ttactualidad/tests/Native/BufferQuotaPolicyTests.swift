import Foundation
import XCTest

final class BufferQuotaPolicyTests: XCTestCase {
    private func reading(_ at: String, used: Int, sent: Int,
                         limit: Int = 2000) -> TTBufferQuotaObservation {
        let data = Data(
            "{\"observed_at\":\"\(at)\",\"used\":\(used),\"limit\":\(limit),\"sent_total\":\(sent)}"
                .utf8)
        return try! JSONDecoder().decode(TTBufferQuotaObservation.self, from: data)
    }

    func testHistoricalIncreaseYieldsObservedRateAndPostsTogether() {
        let a = reading("2026-11-08T06:32:00Z", used: 151, sent: 26)
        let b = reading("2026-11-09T02:11:00Z", used: 193, sent: 34)
        let rate = TTBufferQuotaPolicy.recentRate([b, a])
        XCTAssertEqual(rate?.netRequests, 42)
        XCTAssertEqual(rate?.newConfirmedPosts, 8)
        XCTAssertEqual(rate?.observedRequestsPerNewPost ?? -1, 5.25, accuracy: 0.001)
        XCTAssertNotNil(rate?.netRequestsPerDay)
    }

    func testOneSampleOrTooCloseNeverInventsDailyAverage() {
        let a = reading("2026-11-09T02:11:00Z", used: 193, sent: 34)
        let b = reading("2026-11-09T02:20:00Z", used: 194, sent: 34)
        XCTAssertNil(TTBufferQuotaPolicy.recentRate([a]))
        XCTAssertNil(TTBufferQuotaPolicy.recentRate([a, b]))
    }

    func testRollingWindowDecreasesOrChangesLimitHidesRate() {
        let a = reading("2026-11-08T02:11:00Z", used: 350, sent: 40)
        let b = reading("2026-11-09T02:11:00Z", used: 300, sent: 50)
        XCTAssertNil(TTBufferQuotaPolicy.recentRate([a, b]))
        let c = reading("2026-11-09T02:11:00Z", used: 370, sent: 50, limit: 3000)
        XCTAssertNil(TTBufferQuotaPolicy.recentRate([a, c]))
    }

    func testNoNewPostsShowsRequestPaceWithoutInventingCostPerPost() {
        let a = reading("2026-11-09T02:11:00Z", used: 193, sent: 34)
        let b = reading("2026-11-09T08:11:00Z", used: 210, sent: 34)
        let rate = TTBufferQuotaPolicy.recentRate([a, b])
        XCTAssertEqual(rate?.netRequests, 17)
        XCTAssertNil(rate?.observedRequestsPerNewPost)
    }
}
