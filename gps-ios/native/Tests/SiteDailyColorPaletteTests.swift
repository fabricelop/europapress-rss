import XCTest
@testable import MiMapaDelTiempo

final class SiteDailyColorPaletteTests:XCTestCase {
    func testSameDaySitesAllHaveDifferentColorsForFirstTwelve() {
        let ids=(0..<12).map { _ in UUID() }
        let totals=Dictionary(uniqueKeysWithValues:ids.enumerated().map {
            ($0.element,TimeInterval(($0.offset+1)*60))
        })
        let mapped=SiteDailyColorPalette.indexes(totals)
        XCTAssertEqual(mapped.count,12)
        XCTAssertEqual(Set(mapped.values).count,12)
    }
    func testSameSiteUsesSameColorInLegendAndIntervals() {
        let a=UUID(),b=UUID()
        let totals:[UUID:TimeInterval]=[a:3600,b:600]
        XCTAssertEqual(SiteDailyColorPalette.indexes(totals)[a],0)
        XCTAssertEqual(SiteDailyColorPalette.indexes(totals)[b],1)
        XCTAssertEqual(SiteDailyColorPalette.indexes(totals),
                       SiteDailyColorPalette.indexes(totals))
    }
    func testDayPaletteMayChangeWhenDwellWeightsChange() {
        let a=UUID(),b=UUID()
        XCTAssertNotEqual(SiteDailyColorPalette.indexes([a:300,b:500])[a],
                          SiteDailyColorPalette.indexes([a:700,b:100])[a])
    }
}
