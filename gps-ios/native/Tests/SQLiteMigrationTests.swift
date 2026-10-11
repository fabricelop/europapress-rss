import XCTest
@testable import MiMapaDelTiempo

final class SQLiteMigrationTests: XCTestCase {
    func testMigrationPreservesOldTotalsAndNames() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        var old=SavedState()
        let cell=Cell(row:123,column:456)
        let t0=Date(timeIntervalSince1970:1000), t1=Date(timeIntervalSince1970:1300)
        old.names[cell.id]="Montevalle"
        old.trackingEnabled=true
        old.fixes=[GPSPoint(date:t0,latitude:40.4168,longitude:-3.7038,accuracy:7,source:"gps")]
        old.intervals=[AssignedInterval(start:t0,end:t1,cell:cell,quality:"observado",source:"gps")]
        old.totals[cell.id]=300
        let legacy=folder.appendingPathComponent("time-map-v1.json")
        try JSONEncoder().encode(old).write(to:legacy)
        let db=try TimeSQLiteStore(url:folder.appendingPathComponent("data.sqlite"))
        XCTAssertFalse(db.hasExistingState)
        try db.replaceAll(try JSONDecoder().decode(SavedState.self,from:Data(contentsOf:legacy)))
        let migrated=try db.load()
        XCTAssertEqual(migrated.names[cell.id],"Montevalle")
        XCTAssertEqual(migrated.totals[cell.id],300)
        XCTAssertEqual(migrated.fixes.count,1)
        XCTAssertEqual(migrated.intervals.count,1)
        XCTAssertTrue(migrated.trackingEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath:legacy.path))
    }
    func testAppendDoesNotRecalculatePriorHistory() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db=try TimeSQLiteStore(url:folder.appendingPathComponent("data.sqlite"))
        let base=SavedState()
        try db.replaceAll(base)
        let cell=Cell(row:10,column:20)
        let interval=AssignedInterval(start:Date(timeIntervalSince1970:50),
                end:Date(timeIntervalSince1970:100),cell:cell,quality:"observado",source:"test")
        try db.append(fixes:[],intervals:[interval],totals:[cell.id:50],header:TimeStoreHeader(base))
        XCTAssertEqual(try db.load().totals[cell.id],50)
    }
    func testV1MissingNewFieldStillDecodes() throws {
        let v1=Data(#"{"fixes":[],"intervals":[],"totals":{},"names":{"1:2":"Casa"},"importedHashes":[],"camera":{"latitude":40.4,"longitude":-3.7,"latitudeDelta":0.009,"longitudeDelta":0.009},"missingSeconds":0}"#.utf8)
        let decoded=try JSONDecoder().decode(SavedState.self,from:v1)
        XCTAssertEqual(decoded.names["1:2"],"Casa")
        XCTAssertTrue(decoded.manualBreaks.isEmpty)
    }
}