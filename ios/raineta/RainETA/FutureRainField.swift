import Foundation
import CoreLocation

/// A geographic grid of model precipitation (mm/h), anchored in global
/// Web Mercator coordinates. A model grid is NOT an observed radar frame.
struct FutureRainField {
    let columns: Int
    let rows: Int
    let westX: Double
    let northY: Double
    let eastX: Double
    let southY: Double
    let times: [Date]
    let values: [[Float]]
    let fetchedAt: Date
    let completeness: Double

    static func worldPoint(_ point: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let lat = max(-85, min(85, point.latitude)) * .pi / 180
        return ((point.longitude + 180) / 360,
                (1 - asinh(tan(lat)) / .pi) / 2)
    }

    static func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
        let lat = atan(sinh(.pi * (1 - 2*y))) * 180 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: x*360 - 180)
    }

    /// Sample from model grid using bilinear spatial interpolation and linear
    /// interpolation in time. Missing data is not treated as zero rainfall.
    func rate(x: Double, y: Double, date: Date) -> Double? {
        let col = (x - westX) / max(1e-12, eastX - westX) * Double(columns - 1)
        let row = (y - northY) / max(1e-12, southY - northY) * Double(rows - 1)
        guard col >= 0, row >= 0, col <= Double(columns-1), row <= Double(rows-1),
              let first = times.first, let last = times.last,
              date >= first, date <= last, !values.isEmpty else { return nil }
        let c0 = min(columns - 2, Int(floor(col)))
        let r0 = min(rows - 2, Int(floor(row)))
        let u = col - Double(c0), v = row - Double(r0)

        func frameValue(_ index: Int) -> Double? {
            let frame = values[index]
            guard frame.count == columns*rows else { return nil }
            let a = Double(frame[r0*columns+c0])
            let b = Double(frame[r0*columns+c0+1])
            let c = Double(frame[(r0+1)*columns+c0])
            let d = Double(frame[(r0+1)*columns+c0+1])
            // Refuse to invent rainfall when any contributing model cell is absent.
            guard min(a,b,c,d) >= 0 else { return nil }
            return max(0, (a*(1-u)+b*u)*(1-v) + (c*(1-u)+d*u)*v)
        }

        guard times.count == values.count else { return nil }
        guard let next = times.firstIndex(where: { $0 >= date }) else { return nil }
        if next == 0 { return frameValue(0) }
        let before = next-1
        guard let low = frameValue(before), let high = frameValue(next) else { return nil }
        let period = times[next].timeIntervalSince(times[before])
        let fraction = period > 0 ? max(0, min(1, date.timeIntervalSince(times[before])/period)) : 0
        return low*(1-fraction) + high*fraction
    }

    func covers(center: CLLocationCoordinate2D, latSpan: Double, lonSpan: Double) -> Bool {
        let point = Self.worldPoint(center)
        let north = Self.worldPoint(CLLocationCoordinate2D(latitude: min(85, center.latitude+latSpan*0.35),
                                                           longitude: center.longitude))
        let south = Self.worldPoint(CLLocationCoordinate2D(latitude: max(-85, center.latitude-latSpan*0.35),
                                                           longitude: center.longitude))
        let halfX = lonSpan*0.35/360
        return point.x-halfX > westX && point.x+halfX < eastX &&
               north.y > northY && south.y < southY
    }

    static func makeTestField(center: CLLocationCoordinate2D) -> FutureRainField {
        let p = worldPoint(center)
        let width = 0.025
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = 9, cols = 9
        let rain0: [Float] = (0..<(rows*cols)).map { i in
            let x = Double(i%cols), y = Double(i/cols)
            return Float(max(0, 8 - 1.5*hypot(x-3, y-4)))
        }
        let rain1: [Float] = (0..<(rows*cols)).map { i in
            let x = Double(i%cols), y = Double(i/cols)
            return Float(max(0, 8 - 1.5*hypot(x-5, y-4)))
        }
        return FutureRainField(columns: cols, rows: rows, westX: p.x-width/2,
                               northY: p.y-width/2, eastX: p.x+width/2,
                               southY: p.y+width/2, times: [base,base.addingTimeInterval(3600)],
                               values: [rain0,rain1], fetchedAt: base, completeness: 1)
    }
}

enum FutureRainAPI {
    /// Up to 9x9 points (81 total), downloaded in batches. Each point has
    /// a genuine model forecast; the renderer only interpolates in space/time.
    static func fetch(center: CLLocationCoordinate2D,
                      latSpan: Double, lonSpan: Double) async throws -> FutureRainField {
        let cols = 9, rows = 9
        let centerWorld = FutureRainField.worldPoint(center)
        let halfX = max(0.0014, min(0.06, abs(lonSpan)/360*0.90))
        let upper = CLLocationCoordinate2D(latitude: min(85, center.latitude+max(0.17, latSpan*0.9)),
                                           longitude: center.longitude)
        let lower = CLLocationCoordinate2D(latitude: max(-85, center.latitude-max(0.17, latSpan*0.9)),
                                           longitude: center.longitude)
        let northY = max(0.001, FutureRainField.worldPoint(upper).y)
        let southY = min(0.999, FutureRainField.worldPoint(lower).y)
        let westX = max(0.001, centerWorld.x-halfX)
        let eastX = min(0.999, centerWorld.x+halfX)

        struct Cell { let index:Int; let lat:Double; let lon:Double }
        var cells: [Cell] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let x = westX + (eastX-westX)*Double(col)/Double(cols-1)
                let y = northY + (southY-northY)*Double(row)/Double(rows-1)
                let position = FutureRainField.coordinate(x:x,y:y)
                cells.append(Cell(index: row*cols+col, lat:position.latitude, lon:position.longitude))
            }
        }

        struct Result { let indices:[Int]; let time:[Date]; let rain:[[Float]] }
        // 27 points per request; never send 81 sequential network queries.
        let groups = stride(from: 0, to: cells.count, by: 27).map {
            Array(cells[$0..<min(cells.count,$0+27)])
        }
        let pieces = await withTaskGroup(of: Result?.self) { group -> [Result] in
            for batch in groups {
                group.addTask {
                    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                    components.queryItems = [
                        URLQueryItem(name: "latitude", value: batch.map { String(format:"%.5f",$0.lat) }.joined(separator:",")),
                        URLQueryItem(name: "longitude", value: batch.map { String(format:"%.5f",$0.lon) }.joined(separator:",")),
                        URLQueryItem(name: "minutely_15", value:"precipitation"),
                        URLQueryItem(name: "forecast_minutely_15", value:"25"),
                        URLQueryItem(name: "timezone", value:"GMT"),
                        URLQueryItem(name: "timeformat", value:"unixtime"),
                        URLQueryItem(name: "cell_selection", value:"nearest")
                    ]
                    guard let url = components.url else { return nil }
                    var request = URLRequest(url:url)
                    request.timeoutInterval = 20
                    guard let (data,response) = try? await URLSession.shared.data(for:request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let decoded = try? JSONSerialization.jsonObject(with:data) else { return nil }
                    let places: [[String:Any]]
                    if let multiple = decoded as? [[String:Any]] {
                        places = multiple
                    } else if let only = decoded as? [String:Any] {
                        places = [only]
                    } else { return nil }
                    guard places.count == batch.count else { return nil }
                    var stamp:[Date] = []
                    var values:[[Float]] = []
                    for (index,place) in places.enumerated() {
                        guard let body = place["minutely_15"] as? [String:Any],
                              let times = body["time"] as? [Double],
                              let rates = body["precipitation"] as? [Any],
                              times.count >= 17, times.count == rates.count else { return nil }
                        let newStamp = times.map { Date(timeIntervalSince1970: $0) }
                        if index == 0 { stamp = newStamp }
                        else if newStamp != stamp { return nil }
                        values.append(rates.map { item -> Float in
                            guard let number = item as? NSNumber else { return -1 }
                            // API precipitation is preceding 15-minute SUM in mm.
                            return max(0, number.floatValue*4)
                        })
                    }
                    return Result(indices:batch.map(\.index), time:stamp, rain:values)
                }
            }
            var completed:[Result] = []
            for await result in group { if let result { completed.append(result) } }
            return completed
        }

        guard let canonical = pieces.first?.time, canonical.count >= 17 else {
            throw URLError(.cannotParseResponse)
        }
        let n = min(canonical.count,25)
        let targetDates = Array(canonical.prefix(n))
        var data = Array(repeating: [Float](repeating:-1,count:rows*cols),count:n)
        var loaded = 0
        for part in pieces {
            guard part.time.prefix(n).elementsEqual(targetDates) else { continue }
            for (j,cellIndex) in part.indices.enumerated() {
                for t in 0..<n where t < part.rain[j].count {
                    data[t][cellIndex] = part.rain[j][t]
                }
                loaded += 1
            }
        }
        // Explicit no-data if more than one 27-cell batch failed.
        let completeness = Double(loaded)/Double(rows*cols)
        guard completeness >= 0.66 else { throw URLError(.cannotDecodeContentData) }
        return FutureRainField(columns:cols, rows:rows, westX:westX,northY:northY,
                               eastX:eastX,southY:southY,times:targetDates,
                               values:data,fetchedAt:Date(),completeness:completeness)
    }
}
