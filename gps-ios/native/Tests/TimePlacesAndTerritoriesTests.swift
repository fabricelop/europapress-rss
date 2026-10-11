import XCTest
@testable import MiMapaDelTiempo

final class TimePlacesAndTerritoriesTests: XCTestCase {
    private func segment(_ from:TimeInterval,_ to:TimeInterval,cell:Cell) -> AssignedInterval {
        AssignedInterval(start:Date(timeIntervalSince1970:from),
                         end:Date(timeIntervalSince1970:to),
                         cell:cell,quality:"observado",source:"test")
    }
    func testCanonicalIntervalsNeverCountSameSecondTwice() {
        let a=Cell(row:10,column:11),b=Cell(row:11,column:12)
        let segments=[segment(0,100,cell:a),segment(90,160,cell:b)]
        let normalized=TimeAttribution.canonical(segments)
        XCTAssertEqual(normalized.count,2)
        XCTAssertEqual(normalized[1].start.timeIntervalSince1970,100)
        XCTAssertEqual(TimeAttribution.totals(segments,cellIDs:[a.id,b.id]),160)
        XCTAssertEqual(TimeAttribution.totals(segments,cellIDs:[b.id]),60)
    }
    func testHistoricDailySplitAcrossMidnight() {
        let c=Cell(row:3,column:4)
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let items=[segment(86350,86500,cell:c)]
        let days=TimeAttribution.byDay(items,cellIDs:[c.id],calendar:calendar)
        XCTAssertEqual(days.count,2)
        XCTAssertEqual(days.map(\.seconds).reduce(0,+),150)
    }
    func testPlaceGroupDeduplicatesCellIDs() {
        let group=UserPlace(name:"Casa",cellIDs:["1:2","1:2","1:3"])
        XCTAssertEqual(group.normalizedCellIDs.count,2)
    }
    func testTerritoryHierarchyOmitsUnknownLevels() {
        let territory=TerritoryRecord(country:"España",community:"Madrid",
                   province:nil,city:"Madrid",district:nil,neighborhood:nil)
        XCTAssertEqual(territory.hierarchy.map(\.0),["País","Comunidad/estado","Municipio"])
        XCTAssertNil(TerritoryLevel.neighborhood.value(territory))
    }
    func testShortZoneCodesUniqueAcrossOldCoordinates() {
        let a=Cell(row:145195,column:149400)
        let b=Cell(row:145196,column:149400)
        XCTAssertEqual(FriendlyCellName.title(a,index:1,custom:nil),"Zona 001")
        XCTAssertEqual(FriendlyCellName.title(b,index:2,custom:nil),"Zona 002")
        XCTAssertEqual(FriendlyCellName.title(a,index:1,custom:"Casa"),"Casa")
    }
    func testSavedStateBackwardCompatibleWithoutExtraFields() throws {
        let old=Data(#"{"fixes":[],"intervals":[],"totals":{},"names":{},"importedHashes":[],"camera":{"latitude":40.4,"longitude":-3.7,"latitudeDelta":0.009,"longitudeDelta":0.009},"missingSeconds":0,"trackingEnabled":true}"#.utf8)
        let state=try JSONDecoder().decode(SavedState.self,from:old)
        XCTAssertTrue(state.places.isEmpty)
        XCTAssertTrue(state.territoryCache.isEmpty)
        XCTAssertTrue(state.powerEvents.isEmpty)
        XCTAssertTrue(state.shortIDs.isEmpty)
        XCTAssertTrue(state.trackingEnabled)
    }
    func testNewFieldsPersistInSQLite() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=try TimeSQLiteStore(url:folder.appendingPathComponent("time.sqlite"))
        var state=SavedState()
        let cell=Cell(row:8,column:9)
        state.places=[UserPlace(name:"Trabajo",cellIDs:[cell.id])]
        state.shortIDs[cell.id]=7
        state.territoryCache[cell.id]=TerritoryRecord(country:"España",
                   community:"Madrid",province:"Madrid",city:"Madrid",
                   district:nil,neighborhood:nil)
        state.powerEvents=[GPSPowerEvent(date:Date(timeIntervalSince1970:42),
                                       mode:"Reposo inteligente",cause:"Prueba")]
        try store.replaceAll(state)
        let restored=try store.load()
        XCTAssertEqual(restored.places.count,1)
        XCTAssertEqual(restored.places[0].name,"Trabajo")
        XCTAssertEqual(restored.shortIDs[cell.id],7)
        XCTAssertEqual(restored.territoryCache[cell.id]?.city,"Madrid")
        XCTAssertEqual(restored.powerEvents.count,1)
    }
    func testLegacySQLiteHeaderUpgradesSafely() throws {
        let header=Data(#"{"names":{"1:2":"Casa"},"importedHashes":[],"camera":{"latitude":40.4,"longitude":-3.7,"latitudeDelta":0.009,"longitudeDelta":0.009},"missingSeconds":0,"trackingEnabled":true,"manualBreaks":[]}"#.utf8)
        let decoded=try JSONDecoder().decode(TimeStoreHeader.self,from:header)
        XCTAssertEqual(decoded.names["1:2"],"Casa")
        XCTAssertNil(decoded.places)
        XCTAssertNil(decoded.territoryCache)
        XCTAssertNil(decoded.powerEvents)
        XCTAssertNil(decoded.shortIDs)
    }
}
