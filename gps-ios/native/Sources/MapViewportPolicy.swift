import Foundation
import MapKit

/// Camera-event noise suppression. This only affects redraws/persistence;
/// GPS samples, stored coordinates, and the user's chosen zoom stay untouched.
enum MapViewportPolicy {
    static func meaningfulChange(from old: MKCoordinateRegion, to new: MKCoordinateRegion) -> Bool {
        let values = [new.center.latitude, new.center.longitude,
                      new.span.latitudeDelta, new.span.longitudeDelta]
        guard values.allSatisfy({ $0.isFinite }), new.span.latitudeDelta > 0,
              new.span.longitudeDelta > 0 else { return false }

        let latitudeThreshold = max(0.0000001, abs(old.span.latitudeDelta) * 0.001)
        let longitudeThreshold = max(0.0000001, abs(old.span.longitudeDelta) * 0.001)
        let spanLatitudeThreshold = max(0.0000001, abs(old.span.latitudeDelta) * 0.001)
        let spanLongitudeThreshold = max(0.0000001, abs(old.span.longitudeDelta) * 0.001)
        return abs(new.center.latitude - old.center.latitude) > latitudeThreshold ||
               abs(new.center.longitude - old.center.longitude) > longitudeThreshold ||
               abs(new.span.latitudeDelta - old.span.latitudeDelta) > spanLatitudeThreshold ||
               abs(new.span.longitudeDelta - old.span.longitudeDelta) > spanLongitudeThreshold
    }
}
