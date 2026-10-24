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
    func testTypedVenueOutranksUnrelatedItemsWithinCurrentCell() {
        let falseNearby=SitePlaceResult(id:"statue",name:"Escultura central",
             latitude:40.11,longitude:-3.71,source:.openStreetMap,
             distance:12,inGrid:true)
        let searchedVenue=SitePlaceResult(id:"library",name:"Biblioteca Municipal",
             latitude:40.12,longitude:-3.72,source:.apple,
             distance:190,inGrid:false)
        let ranked=SitePOISearch.ranked([falseNearby,searchedVenue],
                                        query:"Biblioteca Municipal")
        XCTAssertEqual(ranked.first?.id,"library")
        XCTAssertEqual(ranked.count,2)
    }

    func testAccentInsensitiveSearchAndTokenOrder() {
        XCTAssertEqual(SitePOISearch.queryScore("Polideportivo La Masó",
                                               query:"polideportivo la maso"),5)
        XCTAssertEqual(SitePOISearch.queryScore("Centro Deportivo del Barrio",
                                               query:"deportivo centro"),2)
        XCTAssertEqual(SitePOISearch.queryScore("Monumento",
                                               query:"biblioteca"),0)
    }

    func testOsunaServerSearchIncludesSchoolNamesWithoutDownloadTruncation() {
        let center=CLLocationCoordinate2D(latitude:40.455,longitude:-3.594)
        let q=SitePOISearch.overpassQuery(center:center,query:"Osuna")
        XCTAssertTrue(q.contains("[\"amenity\"][\"name\"~"))
        XCTAssertTrue(q.contains("[\"office\"][\"name\"~"))
        XCTAssertTrue(q.contains("5000,40.455,-3.594"))
        // The name matcher goes into Overpass itself, not after fetching
        // a truncated list of unrelated nearby objects.
        XCTAssertFalse(q.contains("out center 180"))
        XCTAssertTrue(q.contains("out center 260"))
    }

    func testColegioSearchFindsSchoolTagsEvenWhenTitleDoesNotSayColegio() {
        let center=CLLocationCoordinate2D(latitude:40.455,longitude:-3.594)
        let q=SitePOISearch.overpassQuery(center:center,query:"Colegio")
        XCTAssertTrue(q.contains("school|college|university|kindergarten"))
        XCTAssertTrue(q.contains("[\"building\"=\"school\"]"))
    }

    func testNearSchoolNamedOsunaPrecedesFarLocalityOsuna() {
        let school=SitePlaceResult(id:"school",name:
            "Centro Privado de Educación Infantil, Primaria y Secundaria Alameda de Osuna",
            latitude:40.45514,longitude:-3.59412,source:.openStreetMap,
            distance:320,inGrid:false)
        let town=SitePlaceResult(id:"town",name:"Osuna",
            latitude:37.2,longitude:-5.1,source:.apple,
            distance:350000,inGrid:false)
        let ranked=SitePOISearch.ranked([town,school],query:"Osuna")
        XCTAssertEqual(ranked.first?.id,"school")
        XCTAssertEqual(ranked.count,2)
    }

    func testNoBusinessNamesHardcodedInNameMatcher() {
        let matcher=SitePOISearch.strongPlaceTerm(in:"Colegio Alameda de Osuna")
        XCTAssertNotNil(matcher)
        XCTAssertNil(SitePOISearch.strongPlaceTerm(in:"Colegio"))
        XCTAssertNil(SitePOISearch.strongPlaceTerm(in:"Polideportivo"))
    }

    func testUnfilteredNearbyPrefersGridAndNearbyLocation() {
        let outside=SitePlaceResult(id:"far",name:"Centro lejano",
              latitude:40,longitude:-3,source:.foursquare,
              distance:950,inGrid:false)
        let local=SitePlaceResult(id:"here",name:"Centro local",
              latitude:40,longitude:-3,source:.apple,
              distance:27,inGrid:true)
        XCTAssertEqual(SitePOISearch.ranked([outside,local]).first?.id,"here")
    }

}
