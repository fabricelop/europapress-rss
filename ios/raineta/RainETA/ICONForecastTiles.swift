import Foundation
import MapKit
import UIKit

/// Real hourly precipitation model maps, directly rendered by the official
/// DWD GeoServer for ICON-EU, at the requested geographical extent.
/// No sparse location-grid, geometry invention or synthetic radar movement.
final class ICONForecastTiles: MKTileOverlay {
    let validTime: Date
    var onFirstTile: (() -> Void)?
    var onTileError: ((String) -> Void)?
    private var reported = false
    private var reportedError = false
    private static let cache: NSCache<NSString, NSData> = {
        let value = NSCache<NSString, NSData>()
        value.countLimit = 250
        value.totalCostLimit = 20 * 1024 * 1024
        return value
    }()

    init(validTime: Date) {
        self.validTime = validTime
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
            guard !self.reported else { return }
            self.reported = true
            self.onFirstTile?()
        }
    }

    private func didFail(_ reason: String) {
        DispatchQueue.main.async {
            guard !self.reportedError else { return }
            self.reportedError = true
            self.onTileError?(reason)
        }
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let url = self.url(forTilePath: path)
        let key = url.absoluteString as NSString
        if let cached = Self.cache.object(forKey: key) {
            result(cached as Data, nil)
            didLoadValidPNG()
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 22
        req.cachePolicy = .returnCacheDataElseLoad
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else {
                result(nil, URLError(.cancelled))
                return
            }
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let data,
                  data.count > 60,
                  data.starts(with: [0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else {
                let reason = "DWD ICON-EU: no se pudo cargar la imagen meteorológica"
                self.didFail(reason)
                result(nil, error ?? URLError(.badServerResponse))
                return
            }
            Self.cache.setObject(data as NSData, forKey: key, cost: data.count)
            result(data, nil)
            self.didLoadValidPNG()
        }.resume()
    }
}
