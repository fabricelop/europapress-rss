import Foundation
import ActivityKit
struct ProbeActivityAttributes:ActivityAttributes {
    struct ContentState:Codable,Hashable {
        var caption:String
        var startedAt:Date
    }
    var title:String="WidgetProbe"
}
