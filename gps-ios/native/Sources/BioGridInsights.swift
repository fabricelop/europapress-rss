import Foundation
import CoreLocation

struct BioGridLiveBirth {
    let secondsRemaining: Int
    let secondsAccumulated: Double
    let provisionalBirths: Int64
    let running: Bool
}

/// Calcula solamente una vista provisional. Nunca escribe tiempo GPS ni genera
/// bacterias persistidas. El ancla corresponde al fin de los intervalos usados
/// para crear la instantánea, no al fin de una caché global no sincronizada.
enum BioGridBirthTicker {
    static func project(remainder: Double,
                        sourceEnd: Date?,
                        visitStart: Date?,
                        latestFix: Date?,
                        now: Date,
                        resting: Bool) -> BioGridLiveBirth {
        let base = min(299.999999, max(0, remainder))
        let origin = max(sourceEnd ?? visitStart ?? now,
                         visitStart ?? .distantPast)
        let running: Bool
        let allowedThrough: Date
        if resting {
            running = true
            allowedThrough = now
        } else if let latestFix,
                  latestFix <= now,
                  now.timeIntervalSince(latestFix) <= 120 {
            running = true
            allowedThrough = now
        } else {
            running = false
            allowedThrough = latestFix.map {
                min(now, $0.addingTimeInterval(120))
            } ?? origin
        }
        let extra = max(0, allowedThrough.timeIntervalSince(origin))
        let completed = Int64((base + extra) / 300.0)
        let elapsed = (base + extra).truncatingRemainder(dividingBy: 300)
        return BioGridLiveBirth(
            secondsRemaining: max(1, Int(ceil(300.0 - elapsed))),
            secondsAccumulated: elapsed,
            provisionalBirths: completed,
            running: running
        )
    }
}

enum BioGridDailyInsights {
    static func headlines(snapshot: BioGridSnapshot, report: BioGridDay?) -> [String] {
        let sorted = snapshot.ranking().sorted {
            $0.population == $1.population
                ? $0.territory > $1.territory
                : $0.population > $1.population
        }
        var result: [String] = []
        if sorted.count >= 2 {
            let lead = sorted[0]
            let runner = sorted[1]
            let difference = lead.population - runner.population
            result.append("\(BioGridEngine.letters[lead.family]) lidera la población con \(lead.population.formatted()) bacterias; \(BioGridEngine.letters[runner.family]) está a \(difference.formatted()) de distancia.")
        } else if let leader = sorted.first {
            result.append("\(BioGridEngine.letters[leader.family]) domina la población con \(leader.population.formatted()) bacterias.")
        }
        guard let report else {
            result.append("Todavía no hay resultados de un ciclo diario completo.")
            return Array(result.prefix(2))
        }
        let champion = (0..<7).max {
            report.conquests[$0] < report.conquests[$1]
        } ?? 0
        let biggest = report.conquests[champion]
        let colonies = report.newCells.reduce(0, +)
        let casualties = report.deaths.reduce(0, +)
        if biggest > 0 {
            result.append("En el último ciclo, \(BioGridEngine.letters[champion]) consiguió \(biggest.formatted()) conquista\(biggest == 1 ? "" : "s").")
        } else if colonies > 0 {
            result.append("El último ciclo fundó \(colonies.formatted()) colonias nuevas.")
        } else if casualties > 0 {
            result.append("El último ciclo registró \(casualties.formatted()) bajas en combate.")
        } else {
            result.append("El último ciclo no registró conquistas ni bajas.")
        }
        return Array(result.prefix(2))
    }

    static func location(_ cell: Cell,
                         zoneName: String?,
                         explicitName: String?,
                         near current: CLLocationCoordinate2D?) -> String {
        if let explicitName,
           !explicitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicitName
        }
        if let zoneName,
           !zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return zoneName
        }
        let point = Grid.center(cell)
        guard let current else {
            return String(format: "Lat. %.4f · Lon. %.4f", point.latitude, point.longitude)
        }
        let distance = CLLocation(latitude: point.latitude, longitude: point.longitude)
            .distance(from: CLLocation(latitude: current.latitude, longitude: current.longitude))
        if distance < 70 { return "En tu zona actual" }
        let dy = point.latitude - current.latitude
        let dx = (point.longitude - current.longitude) *
            cos(current.latitude * .pi / 180)
        let angle = atan2(dx, dy) * 180 / .pi
        let wrapped = (angle + 360).truncatingRemainder(dividingBy: 360)
        let compass = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]
        let direction = compass[Int((wrapped + 22.5) / 45) % 8]
        let amount = distance < 1_000
            ? "\(Int((distance / 10).rounded() * 10)) m"
            : String(format: "%.1f km", distance / 1000)
        return "A \(amount) al \(direction) de ti"
    }
}
