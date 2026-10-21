import Foundation
import UIKit
import CoreLocation

/// Radar-derived, short-horizon *visual extrapolation*. A minute is a display
/// sample, not a newly observed radar frame or an independent model forecast.
struct RadarMinute: Identifiable {
    let minute: Int
    let signal: Double
    let confidence: Double
    var id: Int { minute }
}

struct RadarProjection {
    let image: UIImage
    let worldOriginX: Double
    let worldOriginY: Double
    let dx: Double // displacement in z7 pixels per radar interval
    let dy: Double
    let frameStep: Double
    let confidence: Double
    let observedAt: Date
    let minutePoints: [RadarMinute]

    func opacity(at minute: Int) -> Double {
        let x = Double(max(0, minute))
        let trust = max(0.12, confidence)
        return min(0.95, max(0.32, (0.87 - x / 620) * (0.77 + trust * 0.23)))
    }
    var reliableUntil: Int { max(15, min(90, Int(15 + confidence * 65))) }
}

enum RadarNowcaster {
    static let zoom = 7
    static let tileSize = 256
    static let side = 768
    static let tiny = 256

    private static func tilePosition(_ coordinate: CLLocationCoordinate2D) -> (Double, Double) {
        let latitude = max(-85.0, min(85.0, coordinate.latitude)) * .pi / 180
        let n = pow(2.0, Double(zoom))
        return ((coordinate.longitude + 180.0) / 360.0 * n,
                (1.0 - asinh(tan(latitude)) / .pi) / 2.0 * n)
    }

    private struct Tile {
        let dx: Int
        let dy: Int
        let data: Data
    }
    private static func mosaic(host: String, frame: RadarFrame, tileX: Int, tileY: Int) async throws -> UIImage {
        let worldCount = 1 << zoom
        // One neighboring tile may be absent from a radar service. Missing
        // outskirts must not invalidate the whole forecast for a valid center.
        let tiles = await withTaskGroup(of: Tile?.self) { group in
            for y in 0..<3 {
                for x in 0..<3 {
                    group.addTask {
                        let xx = (tileX + x - 1 + worldCount) % worldCount
                        let yy = min(worldCount - 1, max(0, tileY + y - 1))
                        guard let url = URL(string: "\(host)\(frame.path)/256/7/\(xx)/\(yy)/2/1_1.png") else { return nil }
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 12
                        guard let (bytes, response) = try? await URLSession.shared.data(for: request),
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              UIImage(data: bytes) != nil else { return nil }
                        return Tile(dx: x, dy: y, data: bytes)
                    }
                }
            }
            var collected: [Tile] = []
            for await maybeTile in group {
                if let tile = maybeTile { collected.append(tile) }
            }
            return collected
        }
        // Require actual coverage around the user's point, avoiding a
        // fabricated fully empty mosaic after a partial network failure.
        guard tiles.contains(where: { $0.dx == 1 && $0.dy == 1 }),
              tiles.count >= 3 else { throw URLError(.cannotLoadFromNetwork) }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { context in
                context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
                for tile in tiles {
                    UIImage(data: tile.data)?.draw(in: CGRect(x: tile.dx * tileSize,
                                                              y: tile.dy * tileSize,
                                                              width: tileSize, height: tileSize))
                }
            }
    }

    /// Explicit RGBA bitmap to avoid CoreGraphics alpha-byte-order ambiguity.
    private static func alphaGrid(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: tiny * tiny * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: tiny, height: tiny,
                                      bitsPerComponent: 8, bytesPerRow: tiny * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(tiny))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tiny, height: tiny))
            return true
        }
        guard ok else { return nil }
        return (0..<(tiny * tiny)).map { bytes[$0 * 4 + 3] }
    }

    private struct Movement { let dx: Double; let dy: Double; let confidence: Double }
    private static func movement(old: [UInt8], latest: [UInt8]) -> Movement {
        let grid = tiny, radius = 17, step = 3
        var moves = [(Double, Double, Double)]()
        for cy in stride(from: 35, through: 221, by: 46) {
            for cx in stride(from: 35, through: 221, by: 46) {
                var wet = 0
                for y in stride(from: cy-radius, through: cy+radius, by: step) {
                    for x in stride(from: cx-radius, through: cx+radius, by: step) {
                        if latest[y*grid+x] > 26 { wet += 1 }
                    }
                }
                if wet < 9 { continue }
                var best = -1.0, second = -1.0, bestDx = 0, bestDy = 0
                for dy in -8...8 {
                    for dx in -8...8 {
                        var intersection = 0, union = 0
                        for y in stride(from: cy-radius, through: cy+radius, by: step) {
                            for x in stride(from: cx-radius, through: cx+radius, by: step) {
                                let a = old[(y-dy)*grid+(x-dx)] > 26
                                let b = latest[y*grid+x] > 26
                                if a || b { union += 1; if a && b { intersection += 1 } }
                            }
                        }
                        if union < 7 { continue }
                        let score = Double(intersection)/Double(union)
                        if score > best {
                            second = best
                            best = score
                            bestDx = dx
                            bestDy = dy
                        } else if score > second { second = score }
                    }
                }
                if best > 0.14 {
                    let uniqueness = min(1, max(0, (best-second)/0.055))
                    let quality = max(0.05, min(1, best*0.76 + uniqueness*0.24))
                    moves.append((Double(bestDx), Double(bestDy), quality))
                }
            }
        }
        guard !moves.isEmpty else { return Movement(dx: 0, dy: 0, confidence: 0) }
        let dxSorted = moves.sorted { $0.0 < $1.0 }
        let dySorted = moves.sorted { $0.1 < $1.1 }
        let mx = dxSorted[dxSorted.count / 2].0
        let my = dySorted[dySorted.count / 2].1
        let spread = moves.reduce(0.0) { $0 + hypot($1.0-mx, $1.1-my) } / Double(moves.count)
        let confidence = min(1, (moves.reduce(0.0) { $0 + $1.2 } / Double(moves.count))
                             * max(0.2, 1-spread/6) * min(1, Double(moves.count)/5))
        // Grid is a 3x downsample of the 768px mosaic.
        return Movement(dx: mx*3, dy: my*3, confidence: confidence)
    }

    static func forecast(host: String, frames: [RadarFrame],
                         coordinate: CLLocationCoordinate2D) async -> RadarProjection? {
        guard frames.count >= 2, !host.isEmpty else { return nil }
        let latest = frames[frames.count-1], previous = frames[frames.count-2]
        let interval = Double(latest.timestamp - previous.timestamp) / 60
        guard interval >= 3, interval <= 30 else { return nil }
        let (tx, ty) = tilePosition(coordinate)
        let xi = Int(floor(tx)), yi = Int(floor(ty))
        do {
            async let newImage = mosaic(host: host, frame: latest, tileX: xi, tileY: yi)
            async let oldImage = mosaic(host: host, frame: previous, tileX: xi, tileY: yi)
            let (new, old) = try await (newImage, oldImage)
            guard let a = alphaGrid(old), let b = alphaGrid(new) else { return nil }
            let motion = movement(old: a, latest: b)
            let centerX = (tx - Double(xi-1)) * Double(tileSize) / 3
            let centerY = (ty - Double(yi-1)) * Double(tileSize) / 3
            let minutes = (0...120).map { minute -> RadarMinute in
                let factor = Double(minute) / interval
                let x = centerX - motion.dx * factor / 3
                let y = centerY - motion.dy * factor / 3
                // Approximate local signal by a 5x5 pixel patch to suppress isolated speckles.
                var alpha = 0.0, count = 0.0
                for yy in -2...2 {
                    for xx in -2...2 {
                        let px = Int(x) + xx, py = Int(y) + yy
                        if px >= 0 && px < tiny && py >= 0 && py < tiny {
                            alpha += Double(b[py*tiny+px]) / 255.0
                            count += 1
                        }
                    }
                }
                let fraction = count > 0 ? alpha/count : 0
                let trust = max(0.08, motion.confidence * exp(-Double(minute)/85))
                return RadarMinute(minute: minute, signal: fraction, confidence: trust)
            }
            return RadarProjection(image: new,
                                   worldOriginX: Double(xi-1) * Double(tileSize),
                                   worldOriginY: Double(yi-1) * Double(tileSize),
                                   dx: motion.dx, dy: motion.dy,
                                   frameStep: interval, confidence: motion.confidence,
                                   observedAt: latest.date, minutePoints: minutes)
        } catch {
            return nil
        }
    }
}
