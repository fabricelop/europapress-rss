import Foundation
import CoreLocation

/// Recorrido dibujado por el usuario, nunca reconstrucción GPS observada.
/// Muestras de cinco metros permiten asignar metros de polilínea a las
/// cuadrículas reales (también las intermedias), sin sumar ni un segundo extra.
struct GPSGapRouteAllocation: Identifiable {
    let cell:Cell
    let start:Date
    let end:Date
    let meters:Double
    var id:String { "\(cell.id)-\(start.timeIntervalSince1970)" }
    var seconds:TimeInterval { end.timeIntervalSince(start) }
}

struct GPSGapRoutePlan {
    let gapID:String
    let coordinates:[CLLocationCoordinate2D]
    let allocations:[GPSGapRouteAllocation]
    let distanceMeters:Double
    var cells:[Cell] {
        var seen:Set<Cell>=[]
        return allocations.compactMap { item in
            seen.insert(item.cell).inserted ? item.cell : nil
        }
    }
    var seconds:TimeInterval {
        allocations.reduce(0) { $0+$1.seconds }
    }
    func intervals()->[AssignedInterval] {
        allocations.map {
            AssignedInterval(start:$0.start,end:$0.end,cell:$0.cell,
                quality:"asumido · recorrido estimado por usuario",
                source:"recorrido_estimado")
        }
    }
}

enum GPSGapRoutePlanner {
    static let maxSeconds:TimeInterval=2*3600
    static let cautionSeconds:TimeInterval=30*60
    static let maxMeters:Double=20_000
    static let sampleSpacingMeters:Double=5
    static let maxSamples=6_000
    static let maxCells=200
    static let maxWaypoints=12

    static func endpoints(_ gap:TimeGPSGapReview,
                          fixes:[GPSPoint])->[CLLocationCoordinate2D] {
        let accurate=fixes.filter { $0.accuracy>=0 && $0.accuracy<=45 }
        let origin=accurate.filter {
            $0.cell==gap.previousCell && $0.date<=gap.start &&
            gap.start.timeIntervalSince($0.date)<=180
        }.max(by:{$0.date<$1.date})
        let destination=accurate.filter {
            $0.cell==gap.nextCell && $0.date>=gap.end &&
            $0.date.timeIntervalSince(gap.end)<=180
        }.min(by:{$0.date<$1.date})
        return [origin?.coordinate ?? Grid.center(gap.previousCell),
                destination?.coordinate ?? Grid.center(gap.nextCell)]
    }

    static func preview(gap:TimeGPSGapReview,
                        endpoints:[CLLocationCoordinate2D],
                        via:[CLLocationCoordinate2D])->GPSGapRoutePlan? {
        guard !gap.contradictoryGPS, gap.seconds>=180,
              gap.seconds<=maxSeconds,
              endpoints.count==2,
              via.count<=maxWaypoints else { return nil }
        let points=[endpoints[0]]+via+[endpoints[1]]
        guard points.allSatisfy({
            $0.latitude.isFinite && $0.longitude.isFinite &&
            abs($0.latitude)<=89 && abs($0.longitude)<=180
        }) else { return nil }

        let legDistances=zip(points,points.dropFirst()).map { a,b in
            CLLocation(latitude:a.latitude,longitude:a.longitude)
                .distance(from:CLLocation(latitude:b.latitude,longitude:b.longitude))
        }
        let total=legDistances.reduce(0,+)
        guard total>=5,total<=maxMeters else { return nil }
        let count=legDistances.reduce(0) {
            $0+max(1,Int(ceil($1/sampleSpacingMeters)))
        }
        guard count<=maxSamples else { return nil }
        struct Run {
            var cell:Cell
            var meters:Double
        }
        var runs:[Run]=[]
        for (i,distance) in legDistances.enumerated() {
            let n=max(1,Int(ceil(distance/sampleSpacingMeters)))
            let a=points[i],b=points[i+1]
            for j in 0..<n {
                let t=(Double(j)+0.5)/Double(n)
                let latitude=a.latitude+(b.latitude-a.latitude)*t
                let longitude=a.longitude+(b.longitude-a.longitude)*t
                let cell=Grid.cell(latitude:latitude,longitude:longitude)
                if let last=runs.indices.last,runs[last].cell==cell {
                    runs[last].meters+=distance/Double(n)
                } else {
                    runs.append(Run(cell:cell,meters:distance/Double(n)))
                }
                if runs.count>maxCells { return nil }
            }
        }
        guard !runs.isEmpty else { return nil }
        var allocations:[GPSGapRouteAllocation]=[]
        var usedMeters=0.0
        var currentStart=gap.start
        for i in runs.indices {
            usedMeters+=runs[i].meters
            let end=i==runs.count-1 ? gap.end :
                gap.start.addingTimeInterval(gap.seconds*usedMeters/total)
            guard end>currentStart else { continue }
            allocations.append(GPSGapRouteAllocation(cell:runs[i].cell,
                start:currentStart,end:end,meters:runs[i].meters))
            currentStart=end
        }
        guard allocations.count>0,
              allocations.first?.start==gap.start,
              allocations.last?.end==gap.end else { return nil }
        return GPSGapRoutePlan(gapID:gap.id,coordinates:points,
            allocations:allocations,distanceMeters:total)
    }
}
