import Foundation

/// All places within ONE civil day get different palette positions instead
/// of UUID hashes that often produced similar turquoise/green/blue shades.
/// Colors may change between days; the clock and its legend use one mapping.
enum SiteDailyColorPalette {
    static let count = 12

    static func indexes(_ populationBySite:[UUID:TimeInterval]) -> [UUID:Int] {
        let ordered=populationBySite.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.uuidString < $1.key.uuidString
        }
        return Dictionary(uniqueKeysWithValues:ordered.enumerated().map { index, pair in
            (pair.key,index % count)
        })
    }
}
