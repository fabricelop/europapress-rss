import Foundation

/// Los nombres son descripciones del dato de Apple, no afirmaciones de que
/// coincida exactamente con una provincia/distrito administrativo oficial.
enum TerritoryLevel:String,CaseIterable,Identifiable,Hashable {
    case country,region,subregion,locality,urban
    var id:String { rawValue }
    var title:String {
        switch self {
        case .country:return "Países"
        case .region:return "Regiones"
        case .subregion:return "Subregiones"
        case .locality:return "Ciudades y localidades"
        case .urban:return "Zonas urbanas"
        }
    }
    func value(_ data:TerritoryRecord) -> String? {
        let raw:String?
        switch self {
        case .country:raw=data.country
        case .region:raw=data.community
        case .subregion:raw=data.province
        case .locality:raw=data.city
        case .urban:raw=data.district ?? data.neighborhood
        }
        return raw?.trimmingCharacters(in:.whitespacesAndNewlines).nonEmpty
    }
}
private extension String {
    var nonEmpty:String? { isEmpty ? nil : self }
}
struct TerritoryPart:Identifiable,Hashable {
    var level:TerritoryLevel
    var name:String
    var id:String { level.rawValue+"="+name }
}
struct TerritoryRank:Identifiable {
    var id:String
    var title:String
    var path:[TerritoryPart]
    var seconds:TimeInterval
    var cells:Int
}
/// La jerarquía visual utiliza los niveles presentes. Un campo provincial
/// vacío NO descarta una localidad ni una zona urbana ya geocodificadas.
enum TerritoryGrouping {
    static func path(for record:TerritoryRecord,through level:TerritoryLevel) -> [TerritoryPart] {
        let desired=TerritoryLevel.allCases.firstIndex(of:level) ?? 0
        return TerritoryLevel.allCases.prefix(desired+1).compactMap {
            guard let name=$0.value(record) else { return nil }
            return TerritoryPart(level:$0,name:name)
        }
    }
    static func availableLevels(_ cache:[String:TerritoryRecord],
                                totals:[String:TimeInterval]) -> [TerritoryLevel] {
        let records=totals.compactMap { id,value -> TerritoryRecord? in
            guard value>0 else { return nil }
            return cache[id]
        }
        return TerritoryLevel.allCases.filter { level in
            level == .country || records.contains(where:{level.value($0) != nil})
        }
    }
    static func matches(_ record:TerritoryRecord,scope:[TerritoryPart]) -> Bool {
        scope.allSatisfy { $0.level.value(record) == $0.name }
    }
    static func rows(totals:[String:TimeInterval],
                     cache:[String:TerritoryRecord],
                     level:TerritoryLevel,
                     scope:[TerritoryPart]) -> [TerritoryRank] {
        var result:[String:TerritoryRank]=[:]
        for (cell,seconds) in totals where seconds>0 {
            guard let record=cache[cell],
                  matches(record,scope:scope),
                  level.value(record) != nil else { continue }
            let path=path(for:record,through:level)
            let key=path.map(\.id).joined(separator:" / ")
            guard let last=path.last,last.level==level else { continue }
            var row=result[key] ?? TerritoryRank(id:key,title:last.name,
                                                  path:path,seconds:0,cells:0)
            row.seconds+=seconds
            row.cells+=1
            result[key]=row
        }
        return result.values.sorted {
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            return $0.title.localizedStandardCompare($1.title)==.orderedAscending
        }
    }
    static func nextLevel(after level:TerritoryLevel,
                          scope:[TerritoryPart],
                          totals:[String:TimeInterval],
                          cache:[String:TerritoryRecord]) -> TerritoryLevel? {
        let position=TerritoryLevel.allCases.firstIndex(of:level) ?? 0
        for next in TerritoryLevel.allCases.dropFirst(position+1) {
            if totals.contains(where: { id,value in
                guard value>0,let record=cache[id] else { return false }
                return matches(record,scope:scope) && next.value(record) != nil
            }) { return next }
        }
        return nil
    }
    static func missingLevelSeconds(totals:[String:TimeInterval],
                                    cache:[String:TerritoryRecord],
                                    level:TerritoryLevel,
                                    scope:[TerritoryPart]) -> TimeInterval {
        totals.reduce(0) { sum,item in
            guard let record=cache[item.key],
                  matches(record,scope:scope),
                  level.value(record) == nil else { return sum }
            return sum+item.value
        }
    }
}