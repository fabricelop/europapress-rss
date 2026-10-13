import Foundation
import CoreLocation
import ImageIO
import CoreGraphics

/// EUMETNET OPERA CIRRUS: native, free, 5-minute European radar observations.
/// The decoded COG contains two 32-bit float bands (reflectivity and quality).
/// Nothing in this source generates or labels future radar observations.
enum OperaGeo {
    private static let a = 6_378_137.0
    private static let e = sqrt((1.0/298.257223563) * (2.0 - 1.0/298.257223563))
    private static let lon0 = 10 * Double.pi / 180
    private static let phi0 = 55 * Double.pi / 180

    private static func q(_ phi: Double) -> Double {
        let s = sin(phi), e2 = e*e
        return (1-e2) * (s/(1-e2*s*s) - log((1-e*s)/(1+e*s))/(2*e))
    }

    /// Exact ellipsoidal LAEA as used in official OPERA COG metadata.
    /// Coordinates are in meters; geographical region restricted to Europe.
    static func project(latitude: Double, longitude: Double) -> (x: Double,y: Double)? {
        guard latitude.isFinite,longitude.isFinite,abs(latitude)<=80,abs(longitude)<=180 else { return nil }
        let lat = latitude * Double.pi / 180
        let lon = longitude * Double.pi / 180
        let qp = q(Double.pi/2)
        let rq = a * sqrt(qp/2)
        let b0 = asin(q(phi0)/qp)
        let beta = asin(q(lat)/qp)
        let d = a*cos(phi0)/(rq*cos(b0)*sqrt(1-e*e*pow(sin(phi0),2)))
        let delta = lon-lon0
        let denominator = 1+sin(b0)*sin(beta)+cos(b0)*cos(beta)*cos(delta)
        guard denominator > 0 else { return nil }
        let scale = rq*sqrt(2/denominator)
        let x = 1_950_000 + scale*d*cos(beta)*sin(delta)
        let y = -2_100_000 + scale/d*(cos(b0)*sin(beta)-sin(b0)*cos(beta)*cos(delta))
        return (x,y)
    }

    /// Pixel position corresponding to the first band of an OPERA 1-km COG.
    /// Verified with GeoTIFF transform: x=1000*column-500;
    /// y=500-1000*row, not image-orientation heuristics.
    static func rasterPosition(latitude: Double, longitude: Double) -> (column: Double,row: Double)? {
        guard let point = project(latitude:latitude,longitude:longitude) else { return nil }
        let col = (point.x + 500)/1000
        let row = (500 - point.y)/1000
        guard col >= 0,col < 3800,row >= 0,row < 4400 else { return nil }
        return (col,row)
    }
}

struct OperaCOGFrame {
    let time: Date
    let data: Data

    var image: CGImage? {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),
              let image=CGImageSourceCreateImageAtIndex(source,0,nil),
              image.width==3800,image.height==4400,
              image.bitsPerComponent==32,image.bitsPerPixel==64 else { return nil }
        return image
    }
}

enum OperaCOGError: LocalizedError {
    case noFrames
    case invalidData
    var errorDescription: String? {
        switch self {
        case .noFrames: return "Sin barridos OPERA recientes disponibles."
        case .invalidData: return "Datos radar OPERA incompletos o incompatibles."
        }
    }
}

actor OperaCOGSource {
    private let session: URLSession
    private let directory: URL
    init(session: URLSession = .shared) {
        self.session=session
        let base=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first!
        directory=base.appendingPathComponent("RainETA/OPERA",isDirectory:true)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:nil)
    }

    static func URLForFrame(at time: Date) -> URL {
        let timeZone=TimeZone(secondsFromGMT:0)!
        let day=DateFormatter()
        day.locale=Locale(identifier:"en_US_POSIX")
        day.timeZone=timeZone
        day.dateFormat="yyyy/MM/dd"
        let clock=DateFormatter()
        clock.locale=Locale(identifier:"en_US_POSIX")
        clock.timeZone=timeZone
        clock.dateFormat="yyyyMMdd'T'HHmm"
        let prefix="https://s3.waw3-1.cloudferro.com/openradar-24h/"
        let file="OPERA@\(clock.string(from:time))@0@DBZH.tiff"
        return URL(string:prefix+day.string(from:time)+"/OPERA/COMP/"+file)!
    }

    /// On-demand only. Never run continuously in the background.
    /// At most 7 candidates and 3 full files (~11 MB total), with disk cache.
    func recentFrames(_ requested: Int = 3, now:Date = Date()) async throws -> [OperaCOGFrame] {
        let required=max(1,min(3,requested))
        let rounded=Date(timeIntervalSince1970:floor(now.timeIntervalSince1970/300)*300)
        var frames:[OperaCOGFrame]=[]
        for lag in stride(from:15,through:45,by:5) {
            if frames.count>=required { break }
            let time=rounded.addingTimeInterval(Double(-lag*60))
            let url=Self.URLForFrame(at:time)
            let cache=directory.appendingPathComponent(url.lastPathComponent)
            var bytes:Data?
            if let stored=try? Data(contentsOf:cache),stored.count>500_000 {
                bytes=stored
            } else {
                var request=URLRequest(url:url)
                request.timeoutInterval=22
                request.cachePolicy = .returnCacheDataElseLoad
                if let (data,response)=try? await session.data(for:request),
                   let response=response as? HTTPURLResponse,response.statusCode==200,
                   data.count>500_000 {
                    bytes=data
                    try? data.write(to:cache,options:.atomic)
                }
            }
            guard let data=bytes,
                  data.starts(with:[0x49,0x49,0x2a,0x00]) ||
                  data.starts(with:[0x4d,0x4d,0x00,0x2a]) else { continue }
            frames.append(OperaCOGFrame(time:time,data:data))
        }
        guard frames.count==required else { throw OperaCOGError.noFrames }
        return frames.sorted { $0.time < $1.time }
    }
}
