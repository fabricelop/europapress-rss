import Foundation

/// Read-only projection of the existing BIOGRID simulation's current cell.
/// The Live Activity does NOT create bacteria or update their game state.
enum LiveBioGridPopulation {
    static let familyLetters=["L","M","X","J","V","S","D"]

    static func counts(cellID:String,snapshot:BioGridSnapshot?) -> [Int64]? {
        guard let snapshot else { return nil }
        let existing=snapshot.populations[cellID] ?? []
        return (0..<7).map { index in
            index < existing.count ? max(0,existing[index]) : 0
        }
    }
    static func total(_ counts:[Int64]?) -> Int64? {
        guard let counts else { return nil }
        return counts.reduce(Int64(0),+)
    }
}
