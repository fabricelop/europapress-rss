import XCTest
@testable import MiMapaDelTiempo

final class UnifiedZonesTests: XCTestCase {
    func testExistingNamedPlacesAppearAsZonesWithoutModification() {
        let id=UUID()
        let old=UserPlace(id:id,name:"Montevalle",cellIDs:["20:30","20:31"])
        let zones=TimeZoneCatalog.visible(custom:[],legacy:[old])
        XCTAssertEqual(zones.count,1)
        XCTAssertEqual(zones.first?.id,id)
        XCTAssertEqual(zones.first?.name,"Montevalle")
        XCTAssertEqual(zones.first?.cells,Set(["20:30","20:31"]))
        XCTAssertEqual(old.name,"Montevalle")
    }

    func testCustomZoneWithSameIDDoesNotDuplicateOldPlace() {
        let id=UUID()
        let old=UserPlace(id:id,name:"Nombre anterior",cellIDs:["20:30"])
        let updated=TimeCustomZone(id:id,name:"Nombre nuevo",cellIDs:["20:31"])
        let zones=TimeZoneCatalog.visible(custom:[updated],legacy:[old])
        XCTAssertEqual(zones.count,1)
        XCTAssertEqual(zones[0].name,"Nombre nuevo")
        XCTAssertEqual(zones[0].cells,Set(["20:31"]))
    }

    func testDistinctDrawnAndNamedZonesBothRemain() {
        let old=UserPlace(name:"Casa",cellIDs:["20:30"])
        let drawn=TimeCustomZone(name:"Mi barrio",cellIDs:["20:30","20:31"])
        let list=TimeZoneCatalog.visible(custom:[drawn],legacy:[old])
        XCTAssertEqual(list.count,2)
        XCTAssertEqual(Set(list.map(\.name)),Set(["Casa","Mi barrio"]))
    }
}
