import Foundation

extension GPSHistoryGrouping {
    static func numberOfChunks(_ input: [GPSHistoryFix]) -> Int {
        chunks(input).count
    }
}
