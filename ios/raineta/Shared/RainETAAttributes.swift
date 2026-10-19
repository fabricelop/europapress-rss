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
        // Optional for backward compatibility with activities from earlier
        // RainETA releases. Values encode modelled precipitation phase, not
        // a radar-confirmed rain/snow classification.
        var precipitationKind: String?
        var sourceLabel: String?
        var confidenceLabel: String?
        var radarObservedAt: Date?
        var nextHourBars: [Int]?
        var temperatureC: Double?
    }

    var locationName: String
}
