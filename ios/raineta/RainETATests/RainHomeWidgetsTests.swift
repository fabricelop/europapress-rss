import XCTest
@testable import RainETA

final class RainHomeWidgetsTests: XCTestCase {
    func testDefaultOrderHasAllRainCards() {
        let cards = RainHomeWidget.ordered(from: RainHomeWidget.defaultOrder)
        XCTAssertEqual(cards.count, RainHomeWidget.allCases.count)
        XCTAssertEqual(cards.first, .beforeLeaving)
        XCTAssertEqual(Set(cards), Set(RainHomeWidget.allCases))
    }

    func testOldOrCorruptedPreferencesCannotLoseNewCards() {
        let cards = RainHomeWidget.ordered(from: "radar,radar,obsolete,pulse")
        XCTAssertEqual(cards.first, .radar)
        XCTAssertEqual(cards[1], .pulse)
        XCTAssertEqual(cards.count, RainHomeWidget.allCases.count)
        let visible = RainHomeWidget.visible(order: "radar,pulse", hidden: "models,obsolete")
        XCTAssertFalse(visible.contains(.models))
        XCTAssertEqual(visible.first, .radar)
    }

    func testUnknownIntervalIsNeverPresentedAsDry() {
        let incomplete = [
            RainOverviewBin(startMinute: 0, meanRate: 0, peakRate: 0,
                            rainyMinutes: 0, radarMinutes: 10, snow: false),
            RainOverviewBin(startMinute: 15, meanRate: nil, peakRate: nil,
                            rainyMinutes: 0, radarMinutes: 0, snow: false),
            RainOverviewBin(startMinute: 30, meanRate: 0, peakRate: 0,
                            rainyMinutes: 0, radarMinutes: 0, snow: false),
            RainOverviewBin(startMinute: 45, meanRate: 0, peakRate: 0,
                            rainyMinutes: 0, radarMinutes: 0, snow: false)
        ]
        XCTAssertTrue(RainBeforeLeavingAdvice.headline(incomplete).contains("insuficientes"))
        XCTAssertEqual(RainBeforeLeavingAdvice.description(incomplete[1]), "Sin datos")
    }

    func testLeavingAdviceUsesActualBinsRatherThanAnotherETA() {
        let bins = [0, 15, 30, 45].map { start in
            RainOverviewBin(startMinute: start, meanRate: start == 45 ? 0.3 : 0,
                            peakRate: start == 45 ? 0.6 : 0,
                            rainyMinutes: start == 45 ? 10 : 0,
                            radarMinutes: start < 30 ? 10 : 0, snow: false)
        }
        XCTAssertTrue(RainBeforeLeavingAdvice.headline(bins).contains("Primera media hora"))
    }

    func testDryWindowsBreakAtMissingHour() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let hours = [
            HourlyRain(id: 1, time: now.addingTimeInterval(3600),
                       millimeters: 0, probability: 10, temperature: nil),
            // The second hour is absent: the two periods must NOT be joined.
            HourlyRain(id: 3, time: now.addingTimeInterval(3 * 3600),
                       millimeters: 0, probability: 10, temperature: nil)
        ]
        let windows = RainDryWindowForecast.windows(hours: hours, from: now)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].end.timeIntervalSince(windows[0].start), 3600)
    }

    func testHighProbabilityOrRainPreventsFalseDryWindow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let hours = [
            HourlyRain(id: 0, time: now.addingTimeInterval(3600),
                       millimeters: 0, probability: 90, temperature: nil),
            HourlyRain(id: 1, time: now.addingTimeInterval(7200),
                       millimeters: 0.2, probability: 10, temperature: nil),
            HourlyRain(id: 2, time: now.addingTimeInterval(10800),
                       millimeters: 0, probability: 20, temperature: nil)
        ]
        let windows = RainDryWindowForecast.windows(hours: hours, from: now)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].start, now.addingTimeInterval(7200))
    }
}
