import Foundation
import CoreLocation

enum NameProposal: Equatable {
    case assign(UUID?)
    case distant(UUID, String, Double)
}

enum NamedPlaces {
    static let nearbyMeters:Double=450

    static func normalize(_ text:String) -> String {
        text.trimmingCharacters(in:.whitespacesAndNewlines)
            .folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"es_ES"))
    }

    static func distance(_ a:Cell,_ b:Cell) -> Double {
        let ca=Grid.center(a),cb=Grid.center(b)
        return CLLocation(latitude:ca.latitude,longitude:ca.longitude)
            .distance(from:CLLocation(latitude:cb.latitude,longitude:cb.longitude))
    }

    static func proposal(cell:Cell,name:String,places:[UserPlace]) -> NameProposal {
        let key=normalize(name)
        guard !key.isEmpty else { return .assign(nil) }
        let matches=places.compactMap { p -> (UserPlace,Double)? in
            guard normalize(p.name)==key else { return nil }
            let nearest=p.cellIDs.compactMap(TimeAnalytics.cell).map { distance(cell,$0) }.min()
            guard let nearest else { return nil }
            return (p,nearest)
        }.sorted { $0.1<$1.1 }
        guard let match=matches.first else { return .assign(nil) }
        if match.1<=nearbyMeters || match.0.cellIDs.contains(cell.id) {
            return .assign(match.0.id)
        }
        return .distant(match.0.id,match.0.name,match.1)
    }

    /// Migra nombres anteriores y agrupaciones de v0.5. No cambia tiempo ni GPS.
    static func migrate(names:inout [String:String],places:inout [UserPlace]) {
        // Un grupo explícito de v0.5 es una elección anterior del usuario.
        var assigned=Set<String>()
        for index in places.indices {
            var accepted:[String]=[]
            for id in places[index].cellIDs where !assigned.contains(id) {
                if let existing=names[id],!existing.isEmpty,
                   normalize(existing) != normalize(places[index].name) {
                    continue // priorizar el nombre escrito por el usuario
                }
                names[id]=places[index].name
                accepted.append(id)
                assigned.insert(id)
            }
            places[index].cellIDs=accepted
        }
        places.removeAll { $0.cellIDs.isEmpty }
        // Agrupar solo por mismo nombre y cercanía, sin unir homónimos remotos.
        for (id,name) in names.sorted(by:{$0.key<$1.key}) {
            guard !assigned.contains(id),!normalize(name).isEmpty,
                  let c=TimeAnalytics.cell(id) else { continue }
            switch proposal(cell:c,name:name,places:places) {
            case .assign(let existing):
                if let existing, let i=places.firstIndex(where:{$0.id==existing}) {
                    places[i].cellIDs.append(id)
                } else {
                    places.append(UserPlace(name:name,cellIDs:[id]))
                }
            case .distant:
                places.append(UserPlace(name:name,cellIDs:[id]))
            }
            assigned.insert(id)
        }
    }
}
