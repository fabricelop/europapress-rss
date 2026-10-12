import Foundation
import MapKit

enum MapZoomPolicy {
    static func scaled(_ region:MKCoordinateRegion,factor:Double,
                       center:CLLocationCoordinate2D)->MKCoordinateRegion {
        let f = factor.isFinite ? min(3,max(0.25,factor)) : 1
        let latitude=min(90,max(0.0004,region.span.latitudeDelta*f))
        let longitude=min(90,max(0.0004,region.span.longitudeDelta*f))
        return MKCoordinateRegion(
            center:CLLocationCoordinate2D(
                latitude:min(85,max(-85,center.latitude)),
                longitude:min(179.999,max(-179.999,center.longitude))),
            span:MKCoordinateSpan(latitudeDelta:latitude,longitudeDelta:longitude))
    }
}
