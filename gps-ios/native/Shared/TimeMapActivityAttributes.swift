import Foundation
import ActivityKit

/// La Live Activity recibe solo el nombre visible, estado y el inicio de estancia.
/// No accede a SQLite ni necesita el App Group de WidgetKit.
struct TimeMapActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var cellName: String
        var stayStartedAt: Date
        var resting: Bool
    }
    var title = "Mi Mapa del Tiempo"
}
