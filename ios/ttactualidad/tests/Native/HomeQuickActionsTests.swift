import XCTest
import UIKit

@MainActor
final class HomeQuickActionsTests: XCTestCase {
    func testFourActionsKeepTheirDistinctDestinationsAndCounts() {
        let summary = TTQuickActionSummary(newsReady: 7, trendsReady: 12,
            newsWorking: 3, trendsWorking: 2, pending: 1,
            checkedAt: Date(timeIntervalSince1970: 1_793_354_400))
        let items = HomeQuickActions.items(for: summary)
        XCTAssertEqual(items.map(\.type), TTQuickAction.allCases.map(\.rawValue))
        XCTAssertEqual(items.map(\.localizedTitle), ["Noticias listas (7)",
            "Tendencias listas (12)", "En elaboración (5)", "Órdenes por confirmar (1)"])
        XCTAssertTrue(items[0].localizedSubtitle?.hasPrefix("Última consulta · ") == true)
        XCTAssertTrue(items[3].localizedSubtitle?.hasPrefix("En este iPhone · ") == true)
    }

    func testNoDataDoesNotPretendThatTheListsAreEmpty() {
        let items = HomeQuickActions.items(for: TTQuickActionSummary())
        XCTAssertEqual(items[0].localizedTitle, "Noticias listas")
        XCTAssertEqual(items[1].localizedSubtitle, "Abre para sincronizar")
        XCTAssertEqual(items[2].localizedTitle, "En elaboración")
        XCTAssertEqual(items[3].localizedTitle, "Órdenes por confirmar (0)")
    }

    func testPartialAndOldReadsKeepTheirTimestamp() {
        let date = Date(timeIntervalSince1970: 1_793_354_400)
        let summary = TTQuickActionSummary(newsReady: 0, trendsReady: 0,
            newsWorking: 0, trendsWorking: 0, pending: 0,
            checkedAt: date, partial: true)
        let items = HomeQuickActions.items(for: summary)
        XCTAssertEqual(items[0].localizedTitle, "Noticias listas (0)")
        XCTAssertTrue(items[0].localizedSubtitle?.hasPrefix("Datos parciales · ") == true)
        XCTAssertEqual(summary.checkedAt, date)
    }

    func testColdLaunchRetainsSelectionUntilTheDashboardConsumesIt() {
        let router = HomeQuickActionRouter()
        for action in TTQuickAction.allCases {
            XCTAssertTrue(router.handle(UIApplicationShortcutItem(
                type: action.rawValue, localizedTitle: action.title)))
            let request = try! XCTUnwrap(router.request)
            XCTAssertEqual(request.action, action)
            // SwiftUI may subscribe after the scene configuration callback.
            XCTAssertEqual(router.request, request)
            router.consume(request)
            XCTAssertNil(router.request)
        }
    }

    func testWarmSelectionsHaveUniqueIDsAndCannotBeClearedByAnOlderEvent() {
        let router = HomeQuickActionRouter()
        let item = UIApplicationShortcutItem(type: TTQuickAction.trends.rawValue,
                                             localizedTitle: "Tendencias listas")
        router.handle(item)
        let first = try! XCTUnwrap(router.request)
        router.handle(item)
        let second = try! XCTUnwrap(router.request)
        XCTAssertNotEqual(first.id, second.id)
        router.consume(first)
        XCTAssertEqual(router.request, second)
        router.consume(second)
        XCTAssertNil(router.request)
    }

    func testUnknownActionIsNotHandledAndDoesNotLoseAValidSelection() {
        let router = HomeQuickActionRouter()
        router.handle(UIApplicationShortcutItem(type: TTQuickAction.pending.rawValue,
                                                localizedTitle: "Órdenes"))
        let request = router.request
        XCTAssertFalse(router.handle(UIApplicationShortcutItem(
            type: "unrelated-action", localizedTitle: "Unknown")))
        XCTAssertEqual(router.request, request)
    }

    func testSummarySurvivesRelaunchWithoutLosingTheReadTime() throws {
        let expected = TTQuickActionSummary(newsReady: 4, trendsReady: 9,
            newsWorking: 1, trendsWorking: 3, pending: 2,
            checkedAt: Date(timeIntervalSince1970: 1_793_354_400), partial: true)
        let data = try JSONEncoder().encode(expected)
        XCTAssertEqual(try JSONDecoder().decode(TTQuickActionSummary.self, from: data), expected)
    }
}
