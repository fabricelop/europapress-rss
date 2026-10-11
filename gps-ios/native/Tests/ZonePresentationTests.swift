import XCTest
import CoreLocation
@testable import MiMapaDelTiempo

final class ZonePresentationTests:XCTestCase {
    func testUnnamedGridInZoneInheritsZoneNameWithoutMutatingSavedNames() {
        let zone=TimeCustomZone(name:"Montevalle",cellIDs:["10:20","10:21","11:20","11:21"])
        let match=TimeZoneCatalog.primary(for:"10:21",zones:[zone])
        XCTAssertEqual(match?.name,"Montevalle")
        XCTAssertEqual(match?.cellIDs.count,4)
        XCTAssertNil(TimeZoneCatalog.primary(for:"5:5",zones:[zone]))
    }
    func testOverlapDeterministicSmallestFirst() {
        let big=TimeCustomZone(name:"Provincia propia",cellIDs:["1:1","1:2","2:1","2:2"])
        let small=TimeCustomZone(name:"Casa",cellIDs:["1:1"])
        XCTAssertEqual(TimeZoneCatalog.primary(for:"1:1",zones:[big,small])?.name,"Casa")
        XCTAssertEqual(TimeZoneCatalog.primary(for:"1:1",zones:[small,big])?.name,"Casa")
        XCTAssertEqual(TimeZoneCatalog.primary(for:"2:1",zones:[small,big])?.name,"Provincia propia")
    }
    func testNoLinesBetweenCellsWithinZone() {
        let c=Grid.cell(latitude:40.4,longitude:-3.7)
        let only=TimeCustomZone(name:"Uno",cellIDs:[c.id])
        XCTAssertEqual(TimeZoneOutline.segments(for:only).count,4)
        let east=Cell(row:c.row,column:c.column+1)
        let pair=TimeCustomZone(name:"Dos",cellIDs:[c.id,east.id])
        XCTAssertLessThan(TimeZoneOutline.segments(for:pair).count,8)
    }
    func testLegacyNamedPlaceSurvivesZoneListing() {
        let place=UserPlace(name:"Montevalle",cellIDs:["45:90","45:91"])
        let existing=TimeZoneCatalog.visible(custom:[],legacy:[place])
        XCTAssertEqual(existing.count,1)
        XCTAssertEqual(existing[0].name,"Montevalle")
        XCTAssertEqual(existing[0].cells,Set(["45:90","45:91"]))
    }
}
