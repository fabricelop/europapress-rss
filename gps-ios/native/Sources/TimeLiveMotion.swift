import Foundation
import CoreLocation

struct TimeLiveMovement:Equatable {
    var moving:Bool
    var recentDistanceMeters:Int
    var crossedCells:Int
    var trailIndices:[Int]
    var headingDegrees:Double?
}

/// Analiza muestras GPS observadas en los últimos 15 minutos.
/// Combina puntos próximos hasta superar la incertidumbre de precisión.
enum TimeLiveMotion {
    static func analyze(_ fixes:[GPSPoint], now:Date, center:Cell,
                        latest:GPSPoint? = nil)->TimeLiveMovement {
        var observations=Array(fixes.suffix(500))
        if let latest, latest.date > (observations.last?.date ?? .distantPast) {
            observations.append(latest)
        }
        let recent=observations.filter {
            $0.date<=now && now.timeIntervalSince($0.date)<=900 &&
            $0.accuracy>=0 && $0.accuracy<=100
        }.sorted { $0.date<$1.date }
        guard recent.count>=2 else {
            return TimeLiveMovement(moving:false,recentDistanceMeters:0,
                crossedCells:0,trailIndices:[],headingDegrees:nil)
        }
        var meters=0.0
        var lastThreeMinutes=0.0
        var lastConfirmedAt=Date.distantPast
        var visited:[String]=[]
        var trail:[Int]=[]
        var heading:Double?
        var anchor=recent[0]
        for b in recent.dropFirst() {
            let seconds=b.date.timeIntervalSince(anchor.date)
            if seconds<=0 { continue }
            if seconds>180 {
                anchor=b
                continue
            }
            let origin=CLLocation(latitude:anchor.latitude,longitude:anchor.longitude)
            let destination=CLLocation(latitude:b.latitude,longitude:b.longitude)
            let dist=origin.distance(from:destination)
            if dist>seconds*65+50 {
                anchor=b
                continue
            }
            // El historial conserva muestras a partir de ~16 m; el detector
            // anterior exigía saltos mayores que los puntos almacenados.
            // Acumulamos desplazamiento neto desde un ancla, no ruido GPS.
            let threshold=max(16.0,0.75*(anchor.accuracy+b.accuracy))
            guard dist>=threshold else { continue }
            meters += dist
            if now.timeIntervalSince(b.date)<=180 { lastThreeMinutes += dist }
            lastConfirmedAt=b.date
            for point in [anchor,b] {
                if visited.last != point.cell.id { visited.append(point.cell.id) }
                let deltaR=center.row-point.cell.row
                let deltaC=point.cell.column-center.column
                if abs(deltaR)<=1 && abs(deltaC)<=1 {
                    let index=(deltaR+1)*3+(deltaC+1)
                    if trail.last != index { trail.append(index) }
                }
            }
            let north=(b.latitude-anchor.latitude)*111_000
            let east=(b.longitude-anchor.longitude)*111_000*cos(b.latitude * .pi / 180)
            let degrees=atan2(east,north)*180 / .pi
            heading=(degrees+360).truncatingRemainder(dividingBy:360)
            anchor=b
        }
        let fresh=now.timeIntervalSince(recent.last!.date)<=100
        let moving=fresh && now.timeIntervalSince(lastConfirmedAt)<=100 &&
            lastThreeMinutes>=40 && heading != nil
        return TimeLiveMovement(moving:moving,
            recentDistanceMeters:Int(meters.rounded()),
            crossedCells:max(0,Set(visited).count-1),
            trailIndices:Array(trail.suffix(9)),
            headingDegrees:moving ? heading : nil)
    }
}
