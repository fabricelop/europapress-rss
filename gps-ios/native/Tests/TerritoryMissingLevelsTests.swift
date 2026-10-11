import XCTest
@testable import MiMapaDelTiempo

final class TerritoryMissingLevelsTests:XCTestCase {
    private let madrid=TerritoryRecord(
        country:"España",community:"Comunidad de Madrid",province:nil,
        city:"Madrid",district:"Moncloa",neighborhood:nil,
        timeZoneIdentifier:"Europe/Madrid")
    private let salamanca=TerritoryRecord(
        country:"España",community:"Comunidad de Madrid",province:nil,
        city:"Madrid",district:"Salamanca",neighborhood:nil,
        timeZoneIdentifier:"Europe/Madrid")
    private var totals:[String:TimeInterval] { ["1:2":3600,"1:3":1200] }
    private var cache:[String:TerritoryRecord] {
        ["1:2":madrid,"1:3":salamanca]
    }
    func testMissingProvinceDoesNotHideDistrictsOrLocalities() {
        let local=TerritoryGrouping.rows(totals:totals,cache:cache,
                                          level:.locality,scope:[])
        let urban=TerritoryGrouping.rows(totals:totals,cache:cache,
                                          level:.urban,scope:[])
        XCTAssertEqual(local.count,1)
        XCTAssertEqual(local[0].title,"Madrid")
        XCTAssertEqual(local[0].seconds,4800)
        XCTAssertEqual(Set(urban.map(\.title)),Set(["Moncloa","Salamanca"]))
        XCTAssertEqual(urban.reduce(0) {$0+$1.seconds},4800)
    }
    func testSkipMissingProvinceWhenDrillingDown() {
        let region=TerritoryGrouping.rows(totals:totals,cache:cache,
                                          level:.region,scope:[])
        XCTAssertEqual(region.count,1)
        let next=TerritoryGrouping.nextLevel(after:.region,scope:region[0].path,
                                              totals:totals,cache:cache)
        XCTAssertEqual(next,.locality)
        let city=TerritoryGrouping.rows(totals:totals,cache:cache,
                                         level:next!,scope:region[0].path)
        XCTAssertEqual(city.first?.title,"Madrid")
        let nextUrban=TerritoryGrouping.nextLevel(after:.locality,scope:city[0].path,
                                                   totals:totals,cache:cache)
        XCTAssertEqual(nextUrban,.urban)
    }
    func testSubregionTabHiddenWhenNotProvided() {
        let levels=TerritoryGrouping.availableLevels(cache,totals:totals)
        XCTAssertFalse(levels.contains(.subregion))
        XCTAssertTrue(levels.contains(.urban))
    }
    func testUnknownUrbanLevelNotCountedAsCompletelyUnclassified() {
        let onlyCity=TerritoryRecord(country:"España",community:"Madrid",
            province:nil,city:"Madrid",district:nil,neighborhood:nil,
            timeZoneIdentifier:nil)
        let records=["a":onlyCity]
        let durations=["a":300.0]
        let unavailable=TerritoryGrouping.missingLevelSeconds(totals:durations,
               cache:records,level:.urban,scope:[])
        XCTAssertEqual(unavailable,300)
        XCTAssertEqual(records.count,1)
    }
    func testSameNamesRemainSeparatedByRegion() {
        let other=TerritoryRecord(country:"España",community:"Región distinta",
            province:nil,city:"Madrid",district:"Moncloa",neighborhood:nil,
            timeZoneIdentifier:nil)
        var records=cache
        records["1:4"]=other
        var duration=totals
        duration["1:4"]=120
        let urban=TerritoryGrouping.rows(totals:duration,cache:records,
                                          level:.urban,scope:[])
        XCTAssertEqual(urban.filter {$0.title=="Moncloa"}.count,2)
    }
}
