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

    func isFresh(at now: Date) -> Bool {
        let age=now.timeIntervalSince(observedAt)
        return coverageConfirmed && age >= -180 && age <= 18*60 &&
               now.timeIntervalSince(fetchedAt) < 15*60 && frames.count >= 3
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
    private static let zoom=9
    private static let size=256
    private static let host="https://api.librewxr.net"

    private static func url(path:String,lat:Double,lon:Double,
                            coverage:Bool=false) -> URL? {
        let latPart=String(format:"%.5f",lat)
        let lonPart=String(format:"%.5f",lon)
        let prefix=coverage ? "/v2/coverage/0" : path
        let end=coverage ? "0/0_0.png" : "255/0_0.png"
        return URL(string:"\(host)\(prefix)/256/\(zoom)/\(latPart)/\(lonPart)/\(end)")
    }

    private static func get(_ url:URL) async -> Data? {
        var request=URLRequest(url:url)
        request.timeoutInterval=7
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data,response)=try? await URLSession.shared.data(for:request),
              (response as? HTTPURLResponse)?.statusCode==200,
              data.starts(with:[0x89,0x50,0x4e,0x47]) else{return nil}
        return data
    }

    /// iOS CoreGraphics RGBA sample. Center patch is ~1km at zoom 9 in
    /// Spain, reducing sensitivity to tiny artefacts at exact GPS pixel.
    static func wetFraction(_ data:Data,coverage:Bool=false) -> Double? {
        guard let image=UIImage(data:data)?.cgImage else{return nil}
        var rgba=[UInt8](repeating:0,count:size*size*4)
        let worked=rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx=CGContext(data:raw.baseAddress,width:size,height:size,
                 bitsPerComponent:8,bytesPerRow:size*4,
                 space:CGColorSpaceCreateDeviceRGB(),
                 bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            ctx.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
            return true
        }
        guard worked else {return nil}
        var hits=0, total=0
        for y in 124...132 {
            for x in 124...132 {
                let offset=(y*size+x)*4
                let alpha=Int(rgba[offset+3])
                let brightness=max(rgba[offset],rgba[offset+1],rgba[offset+2])
                if coverage {
                    if alpha > 40 || brightness > 40 {hits+=1}
                } else if alpha>28 && brightness>12 {
                    hits+=1
                }
                total+=1
            }
        }
        return Double(hits)/Double(max(1,total))
    }

    static func fetch(feed:RadarFeed,coordinate:CLLocationCoordinate2D,
                      now:Date=Date()) async -> RadarLocalTimeline? {
        guard feed.source=="LibreWXR", feed.hasNowcast,
              let last=feed.latest,
              now.timeIntervalSince(last.date)>=0,
              now.timeIntervalSince(last.date)<18*60 else{return nil}
        guard let cover=url(path:"",lat:coordinate.latitude,
                            lon:coordinate.longitude,coverage:true),
              let coverageData=await get(cover),
              let coverage=wetFraction(coverageData,coverage:true),
              coverage >= 0.7 else{return nil}
        let picks=Array(feed.frames.suffix(2))+feed.future.filter {
            $0.timestamp>last.timestamp &&
            $0.timestamp<=last.timestamp+70*60
        }
        guard picks.count>=5 else{return nil}
        let sampled=await withTaskGroup(of:RadarLocalFrame?.self) {group in
            for frame in picks {
                group.addTask {
                    guard let tile=url(path:frame.path,lat:coordinate.latitude,
                                       lon:coordinate.longitude),
                          let bytes=await get(tile),
                          let echo=wetFraction(bytes) else{return nil}
                    return RadarLocalFrame(date:frame.date,echo:echo)
                }
            }
            var results:[RadarLocalFrame]=[]
            for await sample in group {if let sample {results.append(sample)}}
            return results.sorted{$0.date<$1.date}
        }
        // Incomplete observations must not be interpreted as dry.
        guard sampled.contains(where:{$0.date==last.date}),
              sampled.filter({$0.date>last.date}).count>=3 else{return nil}
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
            if fresh && minute<=60 {
                echo=radar?.echo(at:date)
            } else if fresh && minute<=90 {
                echo=finalEcho
            } else {
                echo=nil
            }
            let w=radarWeight(at:minute,radarAvailable:echo != nil)
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
