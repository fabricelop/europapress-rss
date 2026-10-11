import XCTest
import CoreLocation
@testable import MiMapaDelTiempo

final class CustomZonesAndBackupTests:XCTestCase {
    func testDrawingPicksWholeGridCellsIncludingUnvisited() {
        let polygon=[
          CLLocationCoordinate2D(latitude:40.416,longitude:-3.706),
          CLLocationCoordinate2D(latitude:40.416,longitude:-3.702),
          CLLocationCoordinate2D(latitude:40.419,longitude:-3.702),
          CLLocationCoordinate2D(latitude:40.419,longitude:-3.706)]
        let selected=TimeZoneGeometry.selectedCells(inside:polygon)
        XCTAssertGreaterThan(selected.count,3)
        XCTAssertLessThan(selected.count,100)
        let inside=Grid.cell(latitude:40.4175,longitude:-3.704)
        XCTAssertTrue(selected.contains(inside.id))
        let outside=Grid.cell(latitude:40.425,longitude:-3.705)
        XCTAssertFalse(selected.contains(outside.id))
    }

    func testOversizedRegionIsRejectedBeforeAllocating() {
        let polygon=[
          CLLocationCoordinate2D(latitude:40.0,longitude:-4.0),
          CLLocationCoordinate2D(latitude:40.0,longitude:-3.0),
          CLLocationCoordinate2D(latitude:40.9,longitude:-3.0),
          CLLocationCoordinate2D(latitude:40.9,longitude:-4.0)]
        XCTAssertTrue(TimeZoneGeometry.selectedCells(inside:polygon).isEmpty)
    }

    func testEncryptedBackupRoundTripAndWrongPassword() throws {
        var state=SavedState()
        state.names["42:5"]="Casa"
        state.customZones=[TimeCustomZone(name:"Zona Casa",cellIDs:["42:5"])]
        state.trackingEnabled=true
        let passphrase="ejemplo no usar como contraseña real 2026"
        let encrypted=try TimeSecureBackup.encrypt(state,password:passphrase)
        XCTAssertFalse(String(decoding:encrypted,as:UTF8.self).contains("Zona Casa"))
        let decoded=try TimeSecureBackup.decrypt(encrypted,password:passphrase)
        XCTAssertEqual(decoded.customZones.count,1)
        XCTAssertEqual(decoded.names["42:5"],"Casa")
        XCTAssertEqual(decoded.trackingEnabled,true)
        XCTAssertThrowsError(try TimeSecureBackup.decrypt(encrypted,password:"otra frase larga"))
    }

    func testHistoricalJSONWithoutZonesStillDecodes() throws {
        let json=Data("{}".utf8)
        let restored=try JSONDecoder().decode(SavedState.self,from:json)
        XCTAssertTrue(restored.customZones.isEmpty)
    }

    func testZoneTimeAttributionCountsOnlyChosenCells() {
        let start=Date(timeIntervalSince1970:1_000)
        let a=Cell(row:10,column:20)
        let b=Cell(row:10,column:21)
        let segments=[
          AssignedInterval(start:start,end:start.addingTimeInterval(12),
                           cell:a,quality:"observado",source:"gps"),
          AssignedInterval(start:start.addingTimeInterval(12),end:start.addingTimeInterval(28),
                           cell:b,quality:"observado",source:"gps")]
        XCTAssertEqual(TimeAttribution.totals(segments,cellIDs:[a.id]),12)
        XCTAssertEqual(TimeAttribution.totals(segments,cellIDs:[b.id]),16)
    }
}
