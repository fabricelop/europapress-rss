import Foundation
import CoreLocation
import UIKit

/// Radar estimates refer to local echoes, not rain-gauge observations.
/// Ten-minute source frames are assigned to minute slots for display; no
/// independent one-minute radar product or calibrated mm/h is implied.
struct RadarLocalFrame: Identifiable {
    let date: Date
    /// Echo coverage around the location (0...1), after speckle reduction.
    let echo: Double
    var id: Date {date}
}

struct RadarLocalTimeline {
    let observedAt: Date
    let fetchedAt: Date
    let frames: [RadarLocalFrame]
    let coverageConfirmed: Bool
    var hasFutureFrames:Bool { frames.contains(where:{$0.date>observedAt}) }

    func isFresh(at now: Date) -> Bool {
        let age=now.timeIntervalSince(observedAt)
        return coverageConfirmed && age >= -180 && age <= 18*60 &&
               now.timeIntervalSince(fetchedAt) < 15*60 && !frames.isEmpty
    }

    /// Nearest frame. These are provider forecasts at ten-minute intervals,
    /// not synthesized minute forecasts. The midpoint is just a display choice.
    func echo(at when: Date) -> Double? {
        guard let first=frames.first,let last=frames.last,
              when >= first.date.addingTimeInterval(-5*60),
              when <= last.date.addingTimeInterval(5*60) else {return nil}
        return frames.min(by:{
            abs($0.date.timeIntervalSince(when)) <
            abs($1.date.timeIntervalSince(when))
        })?.echo
    }

    func isObservedDry(at now: Date) -> Bool? {
        guard isFresh(at:now),
              let observed=frames.filter({$0.date<=observedAt}).last else {return nil}
        return observed.echo < 0.12
    }

    func expectedWet(at when: Date) -> Bool? {
        guard let e=echo(at:when) else{return nil}
        return e >= 0.12
    }
}

enum RadarLocalAPI {
    // Use the *same* palette and native zoom as RainRadarTiles on the visible
    // map. LibreWXR is RainViewer-v2-compatible and takes integer z/x/y
    // Web Mercator tile coordinates, NOT latitude/longitude in those slots.
    static let zoom=7
    static let size=256

    struct TilePoint {
        let x:Int
        let y:Int
        let pixelX:Int
        let pixelY:Int
    }

    static func tilePoint(latitude:Double,longitude:Double) -> TilePoint? {
        guard latitude.isFinite,longitude.isFinite,
              (-85...85).contains(latitude),
              (-180...180).contains(longitude) else {return nil}
        let scale=Double(1 << zoom)
        let phi=latitude * Double.pi/180
        let worldX=(longitude+180)/360*scale
        let worldY=(1-asinh(tan(phi))/Double.pi)/2*scale
        let tx=max(0,min(Int(scale)-1,Int(floor(worldX))))
        let ty=max(0,min(Int(scale)-1,Int(floor(worldY))))
        let px=max(0,min(255,Int((worldX-Double(tx))*256)))
        let py=max(0,min(255,Int((worldY-Double(ty))*256)))
        return TilePoint(x:tx,y:ty,pixelX:px,pixelY:py)
    }

    static func tileURL(host:String,path:String,point:TilePoint) -> URL? {
        guard host.hasPrefix("https://"),path.hasPrefix("/v2/radar/"),
              !path.contains("..") else {return nil}
        return URL(string:"\(host)\(path)/256/\(zoom)/\(point.x)/\(point.y)/2/1_1.png")
    }

    private static func get(_ url:URL) async -> Data? {
        var request=URLRequest(url:url)
        request.timeoutInterval=9
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data,response)=try? await URLSession.shared.data(for:request),
              (response as? HTTPURLResponse)?.statusCode==200,
              data.starts(with:[0x89,0x50,0x4e,0x47]),
              UIImage(data:data) != nil else{return nil}
        return data
    }

    /// Samples exactly the geospatial pixel and its nearest neighbours.
    /// A transparent successful PNG is a genuine *dry* radar tile;
    /// missing/failed PNGs instead return nil (never "dry").
    /// Echo coverage is a qualitative signal, not physically calibrated mm/h.
    static func wetFraction(_ data:Data,point:TilePoint) -> Double? {
        guard let image=UIImage(data:data)?.cgImage,
              image.width==size,image.height==size else{return nil}
        var rgba=[UInt8](repeating:0,count:size*size*4)
        let worked=rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx=CGContext(data:raw.baseAddress,width:size,height:size,
                 bitsPerComponent:8,bytesPerRow:size*4,
                 space:CGColorSpaceCreateDeviceRGB(),
                 bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            // The decoded PNG is already in the tile's top-down pixel
            // orientation when copied into this explicit RGBA bitmap.
            // An extra CoreGraphics flip mirrors Madrid to another latitude.
            ctx.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
            return true
        }
        guard worked else{return nil}
        var hits=0,total=0
        for dy in -3...3 {
            for dx in -3...3 {
                let x=point.pixelX+dx,y=point.pixelY+dy
                guard x>=0,x<size,y>=0,y<size else {continue}
                let p=(y*size+x)*4
                let alpha=Int(rgba[p+3])
                let color=max(Int(rgba[p]),Int(rgba[p+1]),Int(rgba[p+2]))
                if alpha>=30 && color>=10 {hits+=1}
                total+=1
            }
        }
        guard total>=16 else{return nil}
        return Double(hits)/Double(total)
    }

    static func fetch(feed:RadarFeed,coordinate:CLLocationCoordinate2D,
                      now:Date=Date()) async -> RadarLocalTimeline? {
        guard let last=feed.latest,
              let point=tilePoint(latitude:coordinate.latitude,
                                  longitude:coordinate.longitude),
              let _=tileURL(host:feed.host,path:last.path,point:point),
              now.timeIntervalSince(last.date)>=0,
              now.timeIntervalSince(last.date)<18*60 else{return nil}
        let picks=Array(feed.frames.suffix(2))+feed.future.filter {
            $0.timestamp>last.timestamp &&
            $0.timestamp<=last.timestamp+3600
        }
        guard !picks.isEmpty else{return nil}
        let sampled=await withTaskGroup(of:RadarLocalFrame?.self) {group in
            for frame in picks {
                group.addTask {
                    guard let tile=tileURL(host:feed.host,path:frame.path,point:point),
                          let data=await get(tile),
                          let echo=wetFraction(data,point:point) else{return nil}
                    return RadarLocalFrame(date:frame.date,echo:echo)
                }
            }
            var results:[RadarLocalFrame]=[]
            for await value in group {if let value {results.append(value)}}
            return results.sorted{$0.date<$1.date}
        }
        // A confirmed observed tile at the location is our coverage evidence.
        // Do not interpret a failed tile or missing future step as clear sky.
        guard sampled.contains(where:{$0.date==last.date}) else{return nil}
        return RadarLocalTimeline(observedAt:last.date,
                                  fetchedAt:now,frames:sampled,
                                  coverageConfirmed:true)
    }
}

/// One consistent local short-term forecast consumed by countdown, minute
/// pulse, 3-hour chart, and short-range labels in other views.
struct RadarWeightedMinute:Identifiable {
    let minute:Int
    let at:Date
    let rate:Double
    let radarInformed:Bool
    let radarEcho:Double?
    var id:Int {minute}
}

enum RadarWeightedForecast {
    static func radarWeight(at minute:Int,radarAvailable:Bool) -> Double {
        guard radarAvailable else {return 0}
        if minute<=60 {return 1}
        // Beyond the last genuine radar nowcast frame, the radar's final
        // wet/dry state is a LOW-CONFIDENCE trend, faded out by 90 minutes.
        if minute>=90{return 0}
        return Double(90-minute)/30
    }

    static func make(snapshot:RainSnapshot,models:[RainShortModel],
                     radar:RadarLocalTimeline?,now:Date,horizon:Int) -> [RadarWeightedMinute] {
        guard horizon>=0 else{return []}
        let fresh=radar?.isFresh(at:now)==true
        let model=RainPulseFusion.points(samples:snapshot.samples,
                                         models:models,now:now,horizon:horizon)
        let base=Dictionary(uniqueKeysWithValues:model.map{($0.minute,$0.rateMMH)})
        let finalEcho=radar?.frames.last(where:{$0.date>=now})?.echo
        return (0...horizon).compactMap { minute in
            let date=now.addingTimeInterval(Double(minute*60))
            let baseRate=base[minute]
            let echo:Double?
            if fresh && minute==0 {
                // The map at AHORA explicitly displays the last observed
                // frame. Never claim it is raining now from a forecast tile
                // while the visible observed pixel is clear.
                echo=radar?.frames.last(where:{
                    $0.date == radar?.observedAt
                })?.echo
            } else if fresh && radar?.hasFutureFrames == true && minute<=60 {
                echo=radar?.echo(at:date)
            } else if fresh && radar?.hasFutureFrames == true && minute<=90 {
                echo=finalEcho
            } else if fresh && radar?.hasFutureFrames == false && minute<=20 {
                echo=radar?.frames.last(where:{$0.date==radar?.observedAt})?.echo
            } else {
                echo=nil
            }
            let w:Double
            if radar?.hasFutureFrames == false {
                w=echo == nil ? 0 :
                    (minute<=10 ? 1 : minute>=20 ? 0 : Double(20-minute)/10)
            } else {
                w=radarWeight(at:minute,radarAvailable:echo != nil)
            }
            guard let predicted=baseRate ?? echo.map({$0>=0.12 ? 0.4 : 0}) else{return nil}
            // Radar presence/absence gates the model, instead of turning
            // uncalibrated reflectivity into artificial measured mm/h.
            let radarRate:Double
            if let echo,echo>=0.12 {
                radarRate=max(0.3,baseRate ?? 0.5)
            } else {
                radarRate=0
            }
            let value=w*radarRate+(1-w)*predicted
            return RadarWeightedMinute(minute:minute,at:date,
                         rate:max(0,value),radarInformed:w>=0.4,radarEcho:echo)
        }
    }

    static func transition(series:[RadarWeightedMinute],at now:Date,
                           observation:Bool) -> (wet:Bool,change:Date?) {
        guard let first=series.first else{return (observation,nil)}
        let raining=first.radarInformed ? first.rate>=0.15 : observation
        for i in 5..<max(5,series.count-5) {
            let next=Array(series[i..<(i+5)])
            guard next.count==5, next.allSatisfy({
                ($0.rate>=0.15) != raining
            }) else{continue}
            return (raining,series[i].at)
        }
        return (raining,nil)
    }
}
