import XCTest
import Foundation
@testable import MiMapaDelTiempo

final class TimeStorageSafetyTests: XCTestCase {
    func testReopeningDatabaseRetainsHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("time-map-v3.sqlite")
        do {
            let store = try TimeSQLiteStore(url: url)
            var state = SavedState()
            state.fixes = [GPSPoint(date: Date(), latitude: 40.4, longitude: -3.7, accuracy: 5, source: "test")]
            try store.initializeIfTrulyEmpty(state)
            XCTAssertEqual(try store.load().fixes.count, 1)
        }
        let reopened = try TimeSQLiteStore(url: url)
        try reopened.initializeIfTrulyEmpty(SavedState())
        XCTAssertEqual(try reopened.load().fixes.count, 1)
    }
}
