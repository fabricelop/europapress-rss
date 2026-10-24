import XCTest
@testable import MiMapaDelTiempo

final class SitePlaceProviderTests:XCTestCase {
    func testSourcePriorityAndRepeatedNameAcrossProviders() {
        let apple=SitePlaceResult(id:"apple",name:"Polideportivo La Masó",
            latitude:40.1,longitude:-3.7,source:.apple,distance:15,inGrid:true)
        let fsq=SitePlaceResult(id:"fsq",name:"Polideportivo La Masó",
            latitude:40.1001,longitude:-3.7001,source:.foursquare,distance:28,inGrid:true)
        let osm=SitePlaceResult(id:"osm",name:"Polideportivo La Masó",
            latitude:40.10005,longitude:-3.70002,source:.openStreetMap,distance:21,inGrid:true)
        let ranked=SitePOISearch.ranked([apple,osm,fsq])
        XCTAssertEqual(ranked.count,1)
        XCTAssertEqual(ranked.first?.source,.foursquare)
    }
    func testUnrelatedPlacesAreNotRenamedOrMerged() {
        let a=SitePlaceResult(id:"sap",name:"SAP España",latitude:40,longitude:-3,
                              source:.openStreetMap,distance:10,inGrid:true)
        let b=SitePlaceResult(id:"sports",name:"Polideportivo La Masó",
                              latitude:40,longitude:-3,source:.apple,distance:10,inGrid:true)
        XCTAssertEqual(SitePOISearch.ranked([a,b]).count,2)
    }
}
