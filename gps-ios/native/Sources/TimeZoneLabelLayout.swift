import Foundation
import MapKit

/// Limits collisions among *our* named zone labels. Zone outlines and hit
/// areas remain unchanged, so hiding a redundant label never hides a zone.
enum TimeZoneLabelLayout {
    static func visibleIDs(_ overlays: [TimeZoneOverlay],
                           viewport: MKCoordinateRegion,
                           preferredZoneID: UUID? = nil,
                           width: Double = 370,
                           height: Double = 650) -> Set<UUID> {
        guard viewport.span.latitudeDelta > 0,
              viewport.span.longitudeDelta > 0 else { return [] }
        struct Rect {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
            func collides(_ other: Rect) -> Bool {
                abs(x - other.x) < (width + other.width) / 2 + 10 &&
                abs(y - other.y) < (height + other.height) / 2 + 8
            }
        }
        let ordered = overlays.sorted { a, b in
            let aPreferred = a.zone.id == preferredZoneID
            let bPreferred = b.zone.id == preferredZoneID
            if aPreferred != bPreferred { return aPreferred }
            let order = a.zone.name.localizedStandardCompare(b.zone.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.zone.id.uuidString < b.zone.id.uuidString
        }
        var occupied: [Rect] = []
        var visible: Set<UUID> = []
        for overlay in ordered {
            guard let center = overlay.center,
                  center.latitude.isFinite, center.longitude.isFinite else { continue }
            let x = (center.longitude - viewport.center.longitude) /
                    viewport.span.longitudeDelta * width
            let y = (center.latitude - viewport.center.latitude) /
                    viewport.span.latitudeDelta * height
            // The label must be inside the actual screen, not merely in the
            // enlarged set of cached zone outlines.
            guard abs(x) < width / 2, abs(y) < height / 2 else { continue }
            let labelWidth = min(240, max(96, 24 + Double(overlay.zone.name.count) * 6.6))
            let box = Rect(x:x,y:y,width:labelWidth,height:43)
            if occupied.contains(where: { $0.collides(box) }) { continue }
            occupied.append(box)
            visible.insert(overlay.zone.id)
        }
        return visible
    }
}
