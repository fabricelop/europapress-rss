import ActivityKit
import Foundation

// Shared by the app and its ActivityKit/WidgetKit extension.
// Deliberately defines no Home Screen or Lock Screen widgets.
struct LiveCountsAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var newsReady: Int
        var trendsReady: Int
        var checkedAt: Date
        var partialData: Bool
    }

    var title: String
}
