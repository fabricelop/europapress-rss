import Foundation
import ActivityKit

struct RainETAAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var arrival: Date?
        var rainingNow: Bool
        var intensity: String
        var updatedAt: Date
        var summary: String
        // In ContentState so it changes when the selected place changes.
        // Optional to decode activities created by earlier RainETA versions.
        var locationName: String?
    }

    var locationName: String
}
