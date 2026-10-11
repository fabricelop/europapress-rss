import Foundation

// Diary-only classification; never modifies GPS samples or time totals.
extension GPSHistoryGrouping {
    static func episodes(_ fixes: [GPSHistoryFix], manualBreaks: [Date] = []) -> [GPSHistoryEpisode] {
        let orderedBreaks = manualBreaks.sorted()
        return chunks(fixes).flatMap { chunk -> [GPSHistoryEpisode] in
            guard !orderedBreaks.isEmpty else { return classify(chunk) }
            var result: [GPSHistoryEpisode] = []
            var current: [GPSHistoryFix] = []
            for fix in chunk {
                if !current.isEmpty && orderedBreaks.contains(where: {
                    let start = current.last!.date
                    return $0 > start && $0 <= fix.date
                }) {
                    result += classify(current)
                    current = []
                }
                current.append(fix)
            }
            result += classify(current)
            return result
        }
    }

    private static func classify(_ chunk: [GPSHistoryFix]) -> [GPSHistoryEpisode] {
        guard let first = chunk.first else { return [] }
        if chunk.count == 1 {
            return [GPSHistoryEpisode(id: String(first.date.timeIntervalSince1970),
                                      kind: .journey, points: chunk)]
        }
        var result: [GPSHistoryEpisode] = []
        var journeyStart = 0
        var candidateStart = 0
        var cursor = 1

        func add(_ kind: GPSHistoryEpisode.Kind, _ start: Int, _ end: Int) {
            guard end >= start else { return }
            let points = Array(chunk[start...end])
            result.append(GPSHistoryEpisode(
                id: String(points[0].date.timeIntervalSince1970) + "-" + String(start) + "-" + String(end),
                kind: kind, points: points))
        }

        while cursor < chunk.count {
            if distance(chunk[candidateStart], chunk[cursor]) > stayRadius {
                candidateStart = cursor
                cursor += 1
                continue
            }
            let elapsed = chunk[cursor].date.timeIntervalSince(chunk[candidateStart].date)
            if elapsed < stayThreshold {
                cursor += 1
                continue
            }
            var stayEnd = cursor
            while stayEnd + 1 < chunk.count &&
                    distance(chunk[candidateStart], chunk[stayEnd + 1]) <= stayRadius {
                stayEnd += 1
            }
            if candidateStart > journeyStart {
                add(.journey, journeyStart, candidateStart)
            }
            add(.stay, candidateStart, stayEnd)
            journeyStart = stayEnd
            candidateStart = stayEnd
            cursor = stayEnd + 1
        }
        if journeyStart < chunk.count - 1 {
            add(.journey, journeyStart, chunk.count - 1)
        } else if result.isEmpty {
            add(.journey, 0, chunk.count - 1)
        }
        return result
    }
}
