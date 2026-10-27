import ActivityKit
import Foundation

// Shared by the app and its ActivityKit/WidgetKit extension.
// Deliberately defines no Home Screen or Lock Screen widgets.
struct LiveCountsAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var newsReady: Int
        var trendsReady: Int
        var newsWorking: Int
        var trendsWorking: Int
        var pendingActions: Int
        var checkedAt: Date
        var partialData: Bool

        init(newsReady: Int, trendsReady: Int, newsWorking: Int = 0,
             trendsWorking: Int = 0, pendingActions: Int = 0,
             checkedAt: Date, partialData: Bool) {
            self.newsReady = newsReady
            self.trendsReady = trendsReady
            self.newsWorking = newsWorking
            self.trendsWorking = trendsWorking
            self.pendingActions = pendingActions
            self.checkedAt = checkedAt
            self.partialData = partialData
        }

        // A Live Activity from 0.3.2 can still be on the Lock Screen
        // during an upgrade. Its old state lacked the new counters.
        private enum CodingKeys: String, CodingKey {
            case newsReady, trendsReady, newsWorking, trendsWorking
            case pendingActions, checkedAt, partialData
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            newsReady = try values.decode(Int.self, forKey: .newsReady)
            trendsReady = try values.decode(Int.self, forKey: .trendsReady)
            newsWorking = try values.decodeIfPresent(Int.self, forKey: .newsWorking) ?? 0
            trendsWorking = try values.decodeIfPresent(Int.self, forKey: .trendsWorking) ?? 0
            pendingActions = try values.decodeIfPresent(Int.self, forKey: .pendingActions) ?? 0
            checkedAt = try values.decode(Date.self, forKey: .checkedAt)
            partialData = try values.decode(Bool.self, forKey: .partialData)
        }
    }

    var title: String
}
