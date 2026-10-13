import Foundation
import ActivityKit

struct RainETAAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var arrival: Date
        var rainingNow: Bool
        var intensity: String
        var updatedAt: Date
    }

    var locationName: String
}
