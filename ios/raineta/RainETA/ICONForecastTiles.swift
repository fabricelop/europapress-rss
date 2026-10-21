import Foundation
import MapKit
import UIKit

/// Real hourly precipitation model maps, directly rendered by the official
/// DWD GeoServer for ICON-EU, at the requested geographical extent.
/// No sparse location-grid, geometry invention or synthetic radar movement.
final class ICONForecastTiles: MKTileOverlay {
    let validTime: Date
    let upperTime: Date
    let blend: Double
    let requestedTime: Date
    var onFirstTile: (() -> Void)?
    var onTileError: ((String) -> Void)?
    private var reported = false
    private var reportedError = false
    private static let cache: NSCache<NSString, NSData> = {
        let value = NSCache<NSString, NSData>()
        value.countLimit = 420
        value.totalCostLimit = 48 * 1024 * 1024
        return value
    }()

    init(validTime: Date, upperTime: Date? = nil, fraction: Double = 0,
         requestedTime: Date? = nil) {
        self.validTime = validTime
        self.upperTime = upperTime ?? validTime
        self.blend = max(0,min(1,fraction))
        self.requestedTime = requestedTime ?? validTime
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 20
        canReplaceMapContent = false
    }

    static func forecastTime(leadMinutes: Int, now: Date = Date()) -> Date {
        let timestamp = now.addingTimeInterval(Double(max(0, leadMinutes)) * 60)
            .timeIntervalSince1970
        return Date(timeIntervalSince1970: ceil(timestamp / 3600) * 3600)
    }

    /// The displayed 15-minute transition is interpolation between two
    /// actual hourly WMS images, NOT an independent 15-minute forecast.
    static func period(leadMinutes: Int, now:Date=Date()) -> (lower:Date,upper:Date,fraction:Double,target:Date) {
        // Stable minute anchor: re-rendering a SwiftUI view must not start a
        // new WMS request merely because the wall clock advanced one second.
        let minuteAnchor=Date(timeIntervalSince1970:floor(now.timeIntervalSince1970/60)*60)
        let target=minuteAnchor.addingTimeInterval(Double(leadMinutes)*60)
        let base=floor(target.timeIntervalSince1970/3600)*3600
        let lower=Date(timeIntervalSince1970:base)
        return (lower,Date(timeIntervalSince1970:base+3600),
                (target.timeIntervalSince1970-base)/3600,target)
    }

    /// This is a DISPLAY handover, not a forecast of radar echo motion.
    /// Preserve observed radar at the first projected steps so the transition
    /// does not jump instantly to an unrelated hourly NWP field.
    static func transitionWeight(leadMinutes:Int) -> Double {
        let t=Double(max(0,leadMinutes))
        return min(1,max(0,t/30))
    }

    static func covers(_ coordinate: CLLocationCoordinate2D) -> Bool {
        // Conservative central European forecast footprint; WMS itself
        // remains the authority for exact cell coverage.
        (30...73).contains(coordinate.latitude) &&
        (-31...45).contains(coordinate.longitude)
    }

    static func urlForTile(_ tile: MKTileOverlayPath, at time: Date) -> URL? {
        guard (0...20).contains(tile.z) else { return nil }
        let halfWorld = 20_037_508.342789244
        let worldCount = pow(2.0, Double(tile.z))
        let width = 2 * halfWorld / worldCount
        let minX = -halfWorld + Double(tile.x) * width
        let maxX = minX + width
        let maxY = halfWorld - Double(tile.y) * width
        let minY = maxY - width

        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        var request = URLComponents(string: "https://maps.dwd.de/geoserver/dwd/wms")
        request?.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.1.1"),
            URLQueryItem(name: "REQUEST", value: "GetMap"),
            URLQueryItem(name: "LAYERS", value: "dwd:Icon-eu_reg00625_fd_sl_TOTPREC01H"),
            URLQueryItem(name: "STYLES", value: ""),
            URLQueryItem(name: "FORMAT", value: "image/png"),
            URLQueryItem(name: "TRANSPARENT", value: "TRUE"),
            URLQueryItem(name: "SRS", value: "EPSG:3857"),
            URLQueryItem(name: "WIDTH", value: "256"),
            URLQueryItem(name: "HEIGHT", value: "256"),
            URLQueryItem(name: "BBOX",
                         value: [minX,minY,maxX,maxY].map { String(format: "%.3f", $0) }.joined(separator: ",")),
            URLQueryItem(name: "TIME", value: format.string(from: time))
        ]
        return request?.url
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        Self.urlForTile(path, at: validTime)!
    }

    private func didLoadValidPNG() {
        DispatchQueue.main.async {
            guard !self.reported, let onFirstTile=self.onFirstTile else { return }
            self.reported = true
            onFirstTile()
        }
    }

    private func didFail(_ reason: String) {
        DispatchQueue.main.async {
            guard !self.reportedError else { return }
            self.reportedError = true
            self.onTileError?(reason)
        }
    }

    /// DWD default precipitation colours verified on real PNGs.
    static func classStrength(r:UInt8,g:UInt8,b:UInt8,a:UInt8) -> Double {
        if a==0{return 0}
        if abs(Int(r)-192)<=4 && abs(Int(g)-192)<=4 && abs(Int(b)-192)<=4{return 0.25}
        if Int(r)>235 && Int(g)>230 && Int(b)>170{return 0.54}
        if Int(r)>230 && Int(g)>225 && Int(b)>50 && Int(b)<175{return 0.80}
        if Int(r)>200 && Int(g)<150{return 1}
        return 0
    }

    static func palette(_ strength:Double) -> (UInt8,UInt8,UInt8,UInt8) {
        if strength <= 0.001 {return (0,0,0,0)}
        if strength < 0.35 {return (40,195,248,100)}
        if strength < 0.65 {return (15,120,245,173)}
        if strength < 0.88 {return (101,74,246,206)}
        return (245,94,154,224)
    }

    private static func pixels(_ data:Data) -> [UInt8]? {
        guard let image=UIImage(data:data)?.cgImage,
              image.width==256,image.height==256 else{return nil}
        var bytes=[UInt8](repeating:0,count:256*256*4)
        let ok=bytes.withUnsafeMutableBytes { pointer -> Bool in
            guard let ctx=CGContext(data:pointer.baseAddress,width:256,height:256,
                                    bitsPerComponent:8,bytesPerRow:1024,
                                    space:CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            else{return false}
            ctx.draw(image,in:CGRect(x:0,y:0,width:256,height:256))
            return true
        }
        return ok ? bytes : nil
    }

    static func colorize(_ first:Data,_ second:Data?,fraction:Double) -> Data? {
        guard let a=pixels(first) else{return nil}
        let b=second.flatMap{pixels($0)} ?? a
        let t=max(0,min(1,fraction))
        var output=[UInt8](repeating:0,count:a.count)
        for i in stride(from:0,to:a.count,by:4) {
            let low=classStrength(r:a[i],g:a[i+1],b:a[i+2],a:a[i+3])
            let high=classStrength(r:b[i],g:b[i+1],b:b[i+2],a:b[i+3])
            let strength=(1-t)*low+t*high
            let (r,g,blue,alpha)=palette(strength)
            let factor=Double(alpha)/255
            output[i]=UInt8((Double(r)*factor).rounded())
            output[i+1]=UInt8((Double(g)*factor).rounded())
            output[i+2]=UInt8((Double(blue)*factor).rounded())
            output[i+3]=alpha
        }
        return output.withUnsafeMutableBytes { pointer -> Data? in
            guard let ctx=CGContext(data:pointer.baseAddress,width:256,height:256,
                                    bitsPerComponent:8,bytesPerRow:1024,
                                    space:CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image=ctx.makeImage() else {return nil}
            return UIImage(cgImage:image).pngData()
        }
    }

    private func fetch(_ url:URL) async throws -> Data {
        let key=url.absoluteString as NSString
        if let cached=Self.cache.object(forKey:key){return cached as Data}
        var req=URLRequest(url:url)
        req.timeoutInterval=20
        req.cachePolicy = .returnCacheDataElseLoad
        let (data,response)=try await URLSession.shared.data(for:req)
        guard (response as? HTTPURLResponse)?.statusCode==200,
              data.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else {
            throw URLError(.badServerResponse)
        }
        Self.cache.setObject(data as NSData,forKey:key,cost:data.count)
        return data
    }

    /// Fetch a screenful of tiles *before* revealing a new forecast frame.
    /// Old overlays remain visible while either WMS image is loading.
    func prepare(_ paths:[MKTileOverlayPath]) async -> Bool {
        guard !paths.isEmpty else{return false}
        return await withTaskGroup(of:Bool.self) { group in
            for path in paths {
                group.addTask {
                    await withCheckedContinuation { (continuation:CheckedContinuation<Bool,Never>) in
                        self.loadTile(at:path) { data,error in
                            continuation.resume(returning:data != nil && error == nil)
                        }
                    }
                }
            }
            var success=true
            for await ready in group {if !ready {success=false}}
            return success
        }
    }

    override func loadTile(at path:MKTileOverlayPath,
                           result:@escaping(Data?,Error?)->Void) {
        guard let lower=Self.urlForTile(path,at:validTime),
              let upper=Self.urlForTile(path,at:upperTime) else {
            result(nil,URLError(.badURL));return
        }
        let key=("raineta-color:" + lower.absoluteString + "|" +
                 upper.absoluteString + "|\(Int(blend*100))") as NSString
        if let cached=Self.cache.object(forKey:key) {
            result(cached as Data,nil)
            didLoadValidPNG()
            return
        }
        Task {
            do {
                async let first=fetch(lower)
                async let second=fetch(upper)
                let a=try await first
                let b=try await second
                guard let png=Self.colorize(a,b,fraction:blend) else {
                    throw URLError(.cannotDecodeContentData)
                }
                Self.cache.setObject(png as NSData,forKey:key,cost:png.count)
                result(png,nil)
                didLoadValidPNG()
            } catch {
                didFail("Modelo no disponible, continúa el radar observado")
                result(nil,error)
            }
        }
    }
}
