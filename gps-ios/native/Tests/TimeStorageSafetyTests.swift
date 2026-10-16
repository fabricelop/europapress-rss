import XCTest
import Foundation
import SQLite3
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

    func testMissingHeaderWithExistingHistoryCannotReset() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("time-map-v3.sqlite")
        let store = try TimeSQLiteStore(url: url)
        var state = SavedState()
        state.fixes = [GPSPoint(date: Date(), latitude: 40.4, longitude: -3.7, accuracy: 5, source: "test")]
        try store.initializeIfTrulyEmpty(state)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, "DELETE FROM meta WHERE key='header'", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.initializeIfTrulyEmpty(SavedState()))
        XCTAssertThrowsError(try store.load())
        var count: Int32 = 0
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM fixes", -1, &stmt, nil), SQLITE_OK)
        if sqlite3_step(stmt) == SQLITE_ROW { count = sqlite3_column_int(stmt, 0) }
        sqlite3_finalize(stmt)
        XCTAssertEqual(count, 1)
    }
}
