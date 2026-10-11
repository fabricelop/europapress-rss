import Foundation

struct UserPlace: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var cellIDs: [String]

    var normalizedCellIDs: Set<String> { Set(cellIDs) }
}

struct TerritoryRecord: Codable, Equatable {
    var country: String?
    var community: String?
    var province: String?
    var city: String?
    var district: String?
    var neighborhood: String?
    var timeZoneIdentifier: String? = nil

    var hierarchy: [(String, String)] {
        [("País",country),("Comunidad/estado",community),
         ("Provincia",province),("Municipio",city),
         ("Distrito",district),("Barrio",neighborhood)]
        .compactMap { level, value in
            guard let value, !value.isEmpty else { return nil }
            return (level,value)
        }
    }
}

enum TimeAttribution {
    /// Impide que un mismo segundo se sume dos veces a distintos territorios
    /// por importaciones solapadas. Nunca escribe sobre los intervalos originales.
    static func canonical(_ intervals: [AssignedInterval]) -> [AssignedInterval] {
        var coveredThrough = Date.distantPast
        var result: [AssignedInterval] = []
        for item in intervals.sorted(by: {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }) {
            let start = max(item.start, coveredThrough)
            guard start < item.end else { continue }
            result.append(AssignedInterval(id:item.id,start:start,end:item.end,
                         cell:item.cell,quality:item.quality,source:item.source))
            coveredThrough = item.end
        }
        return result
    }
    static func totals(_ segments: [AssignedInterval], cellIDs: Set<String>,
                       window: DateInterval? = nil) -> TimeInterval {
        canonical(segments).reduce(0) { sum, segment in
            guard cellIDs.contains(segment.cell.id) else { return sum }
            let begin = max(segment.start,window?.start ?? .distantPast)
            let end = min(segment.end,window?.end ?? .distantFuture)
            return sum + max(0,end.timeIntervalSince(begin))
        }
    }
    static func byDay(_ segments: [AssignedInterval], cellIDs: Set<String>,
                      calendar: Calendar = .current) -> [(date:Date,seconds:TimeInterval,visits:Int)] {
        var seconds: [Date:TimeInterval] = [:]
        var visits: [Date:Int] = [:]
        var previousEnd: Date?
        for interval in canonical(segments) where cellIDs.contains(interval.cell.id) {
            let separate = previousEnd.map { interval.start.timeIntervalSince($0) > 180 } ?? true
            var cursor = interval.start
            while cursor < interval.end {
                let day = calendar.startOfDay(for:cursor)
                guard let tomorrow = calendar.date(byAdding:.day,value:1,to:day),
                      tomorrow > cursor else { break }
                let limit = min(tomorrow,interval.end)
                seconds[day,default:0] += limit.timeIntervalSince(cursor)
                if separate || cursor == day { visits[day,default:0] += 1 }
                cursor = limit
            }
            previousEnd = interval.end
        }
        return seconds.map { (date:$0.key,seconds:$0.value,visits:visits[$0.key] ?? 0) }
            .sorted { $0.date > $1.date }
    }
    static func byCell(_ segments: [AssignedInterval], window: DateInterval? = nil) -> [String:TimeInterval] {
        var values: [String:TimeInterval] = [:]
        for i in canonical(segments) {
            let start = max(i.start, window?.start ?? .distantPast)
            let end = min(i.end, window?.end ?? .distantFuture)
            if end > start { values[i.cell.id,default:0] += end.timeIntervalSince(start) }
        }
        return values
    }
}

enum FriendlyCellName {
    static func title(_ cell: Cell, index:Int?, custom:String?) -> String {
        if let custom, !custom.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return custom }
        if let index { return "Zona " + String(format:"%03d",index) }
        return "Zona · " + cell.id // si aún no se ha visitado, evitar nombres duplicados
    }
}

