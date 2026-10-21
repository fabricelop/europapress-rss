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
        var precipitationKind: String? = nil
        var sourceLabel: String? = nil
        var confidenceLabel: String? = nil
        var radarObservedAt: Date? = nil
        var nextHourBars: [Int]? = nil
        var temperatureC: Double? = nil
    }

    var locationName: String
}
