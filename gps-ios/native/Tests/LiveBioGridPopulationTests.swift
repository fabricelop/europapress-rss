import XCTest
@testable import MiMapaDelTiempo

final class LiveBioGridPopulationTests:XCTestCase {
    func testReadsSevenActualFamiliesOfCurrentCellOnly() {
        let snapshot=BioGridSnapshot(populations:[
            "10:20":[11,12,13,14,15,16,17],
            "10:21":[99,99,99,99,99,99,99]])
        XCTAssertEqual(LiveBioGridPopulation.counts(cellID:"10:20",snapshot:snapshot),
                       [11,12,13,14,15,16,17])
        XCTAssertEqual(LiveBioGridPopulation.total(
                         LiveBioGridPopulation.counts(cellID:"10:20",snapshot:snapshot)),98)
    }
    func testMissingCellIsZeroOnlyWhenSnapshotExists() {
        XCTAssertNil(LiveBioGridPopulation.counts(cellID:"10:20",snapshot:nil))
        XCTAssertEqual(LiveBioGridPopulation.counts(cellID:"1:1",
                      snapshot:BioGridSnapshot()),[0,0,0,0,0,0,0])
    }
}
