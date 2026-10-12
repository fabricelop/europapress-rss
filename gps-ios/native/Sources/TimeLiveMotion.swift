
import Foundation
import CoreLocation

struct TimeLiveMovement:Equatable {
    var moving:Bool
    var recentDistanceMeters:Int
    var crossedCells:Int
    var trailIndices:[Int]
    var headingDegrees:Double?
}

/// Resumen de los últimos 15 minutos. Solo pares de muestras GPS cercanas
/// en tiempo y con precisión útil; nunca interpola huecos ni viajes imposibles.
enum TimeLiveMotion {
    static func analyze(_ fixes:[GPSPoint],now:Date,center:Cell)->TimeLiveMovement {
        let recent=fixes.suffix(500)
            .filter { $0.date<=now && now.timeIntervalSince($0.date)<=900 &&
                $0.accuracy>=0 && $0.accuracy<=100 }
            .sorted { $0.date<$1.date }
        guard recent.count>=2 else {
            return TimeLiveMovement(moving:false,recentDistanceMeters:0,
                crossedCells:0,trailIndices:[],headingDegrees:nil)
        }
        var meters=0.0
        var lastThreeMinutes=0.0
        var visited:[String]=[]
        var trail:[Int]=[]
        var heading:Double?
        for i in 1..<recent.count {
            let a=recent[i-1],b=recent[i]
            let seconds=b.date.timeIntervalSince(a.date)
            guard seconds>0 && seconds<=180 else { continue }
            let origin=CLLocation(latitude:a.latitude,longitude:a.longitude)
            let destination=CLLocation(latitude:b.latitude,longitude:b.longitude)
            let dist=origin.distance(from:destination)
            guard dist<=seconds*65+50,
                  dist>=max(18,1.2*(a.accuracy+b.accuracy)) else { continue }
            meters += dist
            if now.timeIntervalSince(b.date)<=180 { lastThreeMinutes += dist }
            for point in [a,b] {
                if visited.last != point.cell.id { visited.append(point.cell.id) }
                let deltaR=center.row-point.cell.row
                let deltaC=point.cell.column-center.column
                if abs(deltaR)<=1 && abs(deltaC)<=1 {
                    let index=(deltaR+1)*3+(deltaC+1)
                    if trail.last != index { trail.append(index) }
                }
            }
            let north=(b.latitude-a.latitude)*111_000
            let east=(b.longitude-a.longitude)*111_000*cos(b.latitude * .pi / 180)
            let degrees=atan2(east,north)*180 / .pi
            heading=(degrees+360).truncatingRemainder(dividingBy:360)
        }
        let fresh=now.timeIntervalSince(recent.last!.date)<=100
        let moving=fresh && lastThreeMinutes>=40 && heading != nil
        return TimeLiveMovement(moving:moving,
            recentDistanceMeters:Int(meters.rounded()),
            crossedCells:max(0,Set(visited).count-1),
            trailIndices:Array(trail.suffix(9)),
            headingDegrees:moving ? heading : nil)
    }
}
